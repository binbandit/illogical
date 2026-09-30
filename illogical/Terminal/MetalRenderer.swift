import AppKit
import CoreText
import MetalKit
import QuartzCore

// CAMetalLayer supports background drawable acquisition, but its Objective-C
// interface is not Sendable. No layer properties are mutated on this queue;
// the acquired drawable is transferred once to the main actor before use.
nonisolated private struct MetalDrawableSource: @unchecked Sendable {
    let layer: CAMetalLayer
    func acquire() -> MetalDrawableTransfer { MetalDrawableTransfer(drawable: layer.nextDrawable()) }
}
nonisolated private struct MetalDrawableTransfer: @unchecked Sendable {
    let drawable: CAMetalDrawable?
}

/// One instanced rectangle. Must match `Quad` in Terminal.metal.
private struct TerminalQuad {
    enum Kind: UInt32 {
        case solid = 0, glyph, colorGlyph, image, curlyLine, dottedLine, dashedLine
    }

    var rect: SIMD4<Float>
    var uv: SIMD4<Float> = .zero
    var color: SIMD4<Float>
    var kind: UInt32
    var thickness: Float = 0
    // Metal arrays stride by 64 bytes. Explicit storage also makes a single
    // stack quad safe to upload at that length.
    private var padding: SIMD2<UInt32> = .zero

    init(rect: SIMD4<Float>, uv: SIMD4<Float> = .zero, color: SIMD4<Float>, kind: Kind, thickness: Float = 0) {
        self.rect = rect; self.uv = uv; self.color = color; self.kind = kind.rawValue; self.thickness = thickness
    }

    init(_ rect: CGRect, color: SIMD4<Float>, kind: Kind = .solid) {
        self.init(rect: SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)), color: color, kind: kind)
    }
}

/// Must match `Uniforms` in Terminal.metal.
private struct TerminalUniforms {
    var viewport: SIMD2<Float>
    var cellWidth: Float
    var smoothGlyphs: UInt32
}

/// Premultiplied RGBA from packed 0xRRGGBB.
private func premultiplied(_ value: UInt32, alpha: Float = 1) -> SIMD4<Float> {
    SIMD4(Float((value >> 16) & 255) / 255 * alpha, Float((value >> 8) & 255) / 255 * alpha, Float(value & 255) / 255 * alpha, alpha)
}

@MainActor
private final class TerminalImageTextureCache {
    struct Key: Hashable { let namespace: String; let id: UInt32; let generation: UInt64 }
    private struct Entry { let texture: MTLTexture; let cost: Int; var used: UInt64 }
    /// Kitty `f=` formats as carried by the service.
    private enum Format: Int {
        case rgb = 0, rgba = 1, grayAlpha = 3, gray = 4
        var components: Int {
            switch self {
            case .rgb: 3
            case .rgba: 4
            case .grayAlpha: 2
            case .gray: 1
            }
        }
    }

    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var byteCount = 0
    var count: Int { entries.count }
    let byteLimit: Int
    private let maximumEntries = 1_024
    private let maximumDimension = 16_384

    init(byteLimit: Int = 64 * 1_024 * 1_024) { self.byteLimit = byteLimit }

    func prune(namespace: String, images: [UInt32: WireGraphicsImage]) {
        for key in entries.keys where key.namespace == namespace && images[key.id]?.generation != key.generation { remove(key) }
    }

    private func remove(_ key: Key) {
        if let entry = entries.removeValue(forKey: key) { byteCount -= entry.cost }
    }

    func texture(device: MTLDevice, namespace: String, image: WireGraphicsImage) -> MTLTexture? {
        let key = Key(namespace: namespace, id: image.id, generation: image.generation)
        clock &+= 1
        if var entry = entries[key] {
            entry.used = clock
            entries[key] = entry
            return entry.texture
        }
        let width = Int(image.width), height = Int(image.height)
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension, width * height * 4 <= byteLimit,
              let format = Format(rawValue: image.format), image.data.count == width * height * format.components else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), texture.allocatedSize <= byteLimit else { return nil }
        let region = MTLRegionMake2D(0, 0, width, height)
        let rgba = format == .rgba ? image.data : Self.expandToRGBA(image.data, pixels: width * height, format: format)
        rgba.withUnsafeBytes { texture.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        // A retransmission with the same image ID is new content even when its
        // size is unchanged. Drop its obsolete texture before LRU eviction.
        for old in entries.keys where old.namespace == namespace && old.id == image.id { remove(old) }
        while byteCount + texture.allocatedSize > byteLimit || entries.count >= maximumEntries {
            guard let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key else { break }
            remove(oldest)
        }
        entries[key] = Entry(texture: texture, cost: texture.allocatedSize, used: clock)
        byteCount += texture.allocatedSize
        return texture
    }

    private static func expandToRGBA(_ data: Data, pixels: Int, format: Format) -> Data {
        var rgba = Data(repeating: 255, count: pixels * 4)
        data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            rgba.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                for pixel in 0..<pixels {
                    let input = pixel * format.components, out = pixel * 4
                    switch format {
                    case .rgb:
                        output[out] = source[input]; output[out + 1] = source[input + 1]; output[out + 2] = source[input + 2]
                    case .grayAlpha:
                        output[out] = source[input]; output[out + 1] = source[input]; output[out + 2] = source[input]
                        output[out + 3] = source[input + 1]
                    case .gray:
                        output[out] = source[input]; output[out + 1] = source[input]; output[out + 2] = source[input]
                    case .rgba:
                        preconditionFailure("RGBA images are uploaded directly")
                    }
                }
            }
        }
        return rgba
    }
}

/// Glyph bitmaps for one font, size, scale and option set. Monochrome coverage
/// lives in an R8 texture tinted by the shader; color glyphs get their own
/// RGBA texture, created only when a color glyph first appears.
@MainActor
private final class GlyphAtlas {
    typealias Key = TerminalFontRasterizer.Key
    struct Entry {
        /// Atlas texel rectangle.
        let origin: SIMD2<Float>
        let size: SIMD2<Float>
        /// Bitmap offset from the cell's top-left corner, in device pixels.
        let offset: SIMD2<Float>
        let colored: Bool
        var isEmpty: Bool { size.x == 0 || size.y == 0 }
        static let empty = Entry(origin: .zero, size: .zero, offset: .zero, colored: false)
    }

    /// Row-by-row rectangle packing with one texel of separation.
    private struct ShelfPacker {
        let dimension: Int
        var x = 0, y = 0, rowHeight = 0

        mutating func place(width: Int, height: Int) -> (x: Int, y: Int)? {
            guard width < dimension, height < dimension else { return nil }
            if x + width >= dimension { x = 0; y += rowHeight + 1; rowHeight = 0 }
            guard y + height < dimension else { return nil }
            defer { x += width + 1; rowHeight = max(rowHeight, height) }
            return (x, y)
        }
    }

    static let dimension = 2_048
    private static let maximumEntries = 65_536
    let device: MTLDevice
    let rasterizer: TerminalFontRasterizer
    var metrics: TerminalCellMetrics { rasterizer.metrics }
    let grayscale: MTLTexture
    private(set) var color: MTLTexture?
    private var entries: [Key: Entry] = [:]
    /// Single-column ASCII, the overwhelmingly common case, skips hashing.
    private var ascii = [Entry?](repeating: nil, count: 128 * 4)
    private var grayscalePacker = ShelfPacker(dimension: dimension)
    private var colorPacker = ShelfPacker(dimension: dimension)
    /// Once capacity is exhausted, misses cannot fit. Avoid repeatedly
    /// rasterizing them until the renderer replaces the atlas.
    private(set) var full = false

    init?(device: MTLDevice, font: NSFont, scale: CGFloat, options: TerminalFontOptions) {
        self.device = device
        rasterizer = TerminalFontRasterizer(font: font, scale: scale, options: options)
        guard let texture = Self.makeTexture(device: device, format: .r8Unorm) else { return nil }
        grayscale = texture
    }

    private static func makeTexture(device: MTLDevice, format: MTLPixelFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: dimension, height: dimension, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    func asciiGlyph(_ byte: UInt8, style: TerminalFontRasterizer.Style) -> Entry? {
        let slot = Int(byte) * 4 + Int(style.rawValue & 3)
        if let cached = ascii[slot] { return cached }
        let key = Key(text: String(UnicodeScalar(byte)), bold: style.contains(.bold), italic: style.contains(.italic))
        let entry = glyph(key)
        ascii[slot] = entry
        return entry
    }

    func glyph(_ key: Key) -> Entry? {
        if let cached = entries[key] { return cached }
        // Blank entries take no texels; the key count bounds their memory.
        if entries.count >= Self.maximumEntries { full = true }
        guard !full else { return nil }
        // An unrenderable or blank glyph is cached as empty, not retried.
        guard let bitmap = rasterizer.rasterize(key), !bitmap.isEmpty else {
            entries[key] = .empty
            return .empty
        }
        if bitmap.colored && color == nil { color = Self.makeTexture(device: device, format: .rgba8Unorm) }
        guard let texture = bitmap.colored ? color : grayscale,
              let position = bitmap.colored ? colorPacker.place(width: bitmap.width, height: bitmap.height)
                                            : grayscalePacker.place(width: bitmap.width, height: bitmap.height) else {
            full = true
            return nil
        }
        bitmap.pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(position.x, position.y, bitmap.width, bitmap.height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: bitmap.width * bitmap.bytesPerPixel)
        }
        let entry = Entry(origin: SIMD2(Float(position.x), Float(position.y)), size: SIMD2(Float(bitmap.width), Float(bitmap.height)),
                          offset: SIMD2(Float(bitmap.left), Float(bitmap.top)), colored: bitmap.colored)
        entries[key] = entry
        return entry
    }
}

/// Where the grid lands in the drawable, in points.
private struct GridLayout {
    let metrics: TerminalCellMetrics
    let scale: CGFloat
    /// Uniform scale of non-interactive previews that fit the whole grid.
    let fit: CGFloat
    let inset: CGFloat
    /// Points per device pixel of the grid.
    var pixel: CGFloat { fit / scale }
    var cellWidth: CGFloat { CGFloat(metrics.cellWidth) * pixel }
    var cellHeight: CGFloat { CGFloat(metrics.cellHeight) * pixel }

    func cellRect(column: Int, row: Int, columns: Int = 1) -> CGRect {
        CGRect(x: inset + CGFloat(column) * cellWidth, y: inset + CGFloat(row) * cellHeight,
               width: cellWidth * CGFloat(columns), height: cellHeight)
    }

    /// A horizontal stroke `top` device pixels below the cell's top edge.
    func stroke(in cell: CGRect, top: Int, height: Int) -> CGRect {
        CGRect(x: cell.minX, y: cell.minY + CGFloat(top) * pixel, width: cell.width, height: CGFloat(height) * pixel)
    }
}

/// Accumulates one frame's quads. A local value avoids class property
/// exclusivity checks in the per-cell loop.
private struct QuadBuilder {
    var backgrounds: [TerminalQuad]
    var foregrounds: [TerminalQuad]
    let layout: GridLayout

    mutating func background(_ rect: CGRect, _ color: UInt32, alpha: Float = 1) {
        backgrounds.append(TerminalQuad(rect, color: premultiplied(color, alpha: alpha)))
    }

    mutating func solid(_ rect: CGRect, _ color: UInt32, alpha: Float = 1) {
        foregrounds.append(TerminalQuad(rect, color: premultiplied(color, alpha: alpha)))
    }

    mutating func glyph(_ entry: GlyphAtlas.Entry, cell: CGRect, color: UInt32) {
        let pixel = Float(layout.pixel)
        let origin = SIMD2(Float(cell.minX), Float(cell.minY)) + entry.offset * pixel
        let size = entry.size * pixel
        foregrounds.append(TerminalQuad(rect: SIMD4(origin.x, origin.y, size.x, size.y), uv: SIMD4(lowHalf: entry.origin, highHalf: entry.size),
                                        color: entry.colored ? SIMD4(repeating: 1) : premultiplied(color),
                                        kind: entry.colored ? .colorGlyph : .glyph))
    }

    /// Underlines, strikethrough and overline, placed by the font's metrics.
    mutating func decorations(_ cell: ILCell, in rect: CGRect, foreground: UInt32) {
        let metrics = layout.metrics, flags = cell.styleFlags
        // Strokes may extend a quarter cell beyond the grid row, like Ghostty's sprites.
        let overhang = metrics.cellHeight / 4
        if flags.contains(.underline) {
            let color = cell.styleAttributes.contains(.underlineColor) ? cell.underlineColor : foreground
            let thickness = metrics.underlineThickness
            let top = min(metrics.underlinePosition, metrics.cellHeight + overhang - thickness)
            switch cell.underline {
            case .none, .single:
                solid(layout.stroke(in: rect, top: top, height: thickness), color)
            case .double:
                let top = min(metrics.underlinePosition, metrics.cellHeight + overhang - 2 * thickness)
                solid(layout.stroke(in: rect, top: top - thickness, height: thickness), color)
                solid(layout.stroke(in: rect, top: top + thickness, height: thickness), color)
            case .curly:
                let amplitude = Int((CGFloat(metrics.cellWidth) / .pi).rounded(.up))
                let curlTop = min(top, metrics.cellHeight + overhang - amplitude - thickness)
                pattern(.curlyLine, rect, top: curlTop - thickness / 2, height: amplitude + thickness, thickness: thickness, color: color)
            case .dotted:
                let radius = Int((CGFloat(thickness) * 0.7071).rounded(.up))
                pattern(.dottedLine, rect, top: top + thickness / 2 - radius, height: radius * 2, thickness: thickness, color: color)
            case .dashed:
                pattern(.dashedLine, rect, top: top, height: thickness, thickness: thickness, color: color)
            }
        }
        if flags.contains(.strikethrough) {
            solid(layout.stroke(in: rect, top: metrics.strikethroughPosition, height: metrics.strikethroughThickness), foreground)
        }
        if flags.contains(.overline) {
            solid(layout.stroke(in: rect, top: max(metrics.overlinePosition, -overhang), height: metrics.overlineThickness), foreground)
        }
    }

    /// A procedural stroke whose pattern coordinates are device pixels
    /// relative to the first cell, so every cell repeats the same shape.
    private mutating func pattern(_ kind: TerminalQuad.Kind, _ cell: CGRect, top: Int, height: Int, thickness: Int, color: UInt32) {
        let rect = layout.stroke(in: cell, top: top, height: height)
        let width = Float(cell.width / layout.pixel)
        foregrounds.append(TerminalQuad(rect: SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)),
                                        uv: SIMD4(0, 0, width, Float(height)), color: premultiplied(color), kind: kind,
                                        thickness: Float(thickness)))
    }
}

@MainActor
final class MetalTerminalRenderer: NSObject, MTKViewDelegate {
    static let device = MTLCreateSystemDefaultDevice()
    /// Grid inset from the view's top-left corner, in points.
    nonisolated static let padding: CGFloat = 8

    private struct AtlasKey: Hashable {
        let font: String
        let size: CGFloat
        let scale: CGFloat
        let options: TerminalFontOptions
    }
    private struct ImageDraw {
        var quad: TerminalQuad
        let texture: MTLTexture
        let z: Int32
    }
    /// Kitty z-index bands: below cell backgrounds, between backgrounds and
    /// text, and above text.
    private enum ImageLayer {
        static func belowBackgrounds(_ z: Int32) -> Bool { z < Int32.min / 2 }
        static func belowText(_ z: Int32) -> Bool { z >= Int32.min / 2 && z < 0 }
        static func aboveText(_ z: Int32) -> Bool { z >= 0 }
    }
    private enum SearchColors {
        static let selectedBackground: UInt32 = 0xe3ba64, selectedForeground: UInt32 = 0x2b2314
        static let matchBackground: UInt32 = 0x81714d, matchForeground: UInt32 = 0xffffff
    }
    /// Runs of ligature symbols are shaped together up to this length.
    private static let maximumOperatorRun = 24

    private static let atlases = TerminalResourcePool<AtlasKey, GlyphAtlas>()
    private static let imageTextures = TerminalImageTextureCache()
    private static var sharedPipeline: MTLRenderPipelineState?
    private static var sharedBackgroundPipeline: MTLRenderPipelineState?

    private let engine: TerminalEngine
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let observer = UUID()
    private var buffers: [MTLBuffer?] = [nil, nil, nil]
    private var backgrounds: [TerminalQuad] = []
    private var foregrounds: [TerminalQuad] = []
    private var operatorBytes: [UInt8] = []
    private var geometryCapacity = TerminalGeometryCapacity()
    private var atlas: GlyphAtlas?
    private var atlasKey: AtlasKey?
    private let drawableQueue = DispatchQueue(label: "illogical.metal.drawable", qos: .userInteractive)
    private var presentation = TerminalPresentationState()
    private var textBlink = TerminalTextBlinkState()
    private var textBlinkTimer: Timer?
    private var contrastCache: [UInt64: UInt32] = [:]
    private var contrastTarget: UInt32?
    private var contrastMinimum: Double?
    private var fontCache: NSFont?
    private var metricsCache: (scale: CGFloat, metrics: TerminalCellMetrics)?
    private var displayedGraphics = TerminalGraphicsState()
    private var graphicsNamespace: String?
    private var imageDraws: [ImageDraw] = []

    weak var view: MTKView?
    var fontSize = TerminalFontOptions.defaultFontSize { didSet { if fontSize != oldValue { invalidateFont() } } }
    var fontName = TerminalFontOptions.defaultFontName { didSet { if fontName != oldValue { invalidateFont() } } }
    var fontOptions = TerminalFontOptions.defaults { didSet { if fontOptions != oldValue { invalidateFont() } } }
    var focused = false
    /// False for scaled previews, which fit the whole grid and draw no cursor outline.
    var interactive = true
    var contrastCorrection = true
    /// The cursor's blink phase, toggled by the surface's blink timer.
    var cursorOn = true
    var onFrame: ((ILFrame) -> Void)?

    private func invalidateFont() {
        fontCache = nil; metricsCache = nil; atlas = nil; atlasKey = nil
    }

    private var backingScale: CGFloat { view?.window?.backingScaleFactor ?? 2 }

    var font: NSFont {
        if let fontCache { return fontCache }
        TerminalBundledFonts.register()
        // Unknown names, including "SF Mono", use the system monospace face.
        let base = NSFont(name: fontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let resolved = TerminalFontRasterizer.configuredFont(base as CTFont, options: fontOptions) as NSFont
        fontCache = resolved
        return resolved
    }

    /// Device-pixel grid metrics at the current backing scale.
    var metrics: TerminalCellMetrics {
        let scale = backingScale
        if let metricsCache, metricsCache.scale == scale { return metricsCache.metrics }
        let scaled = CTFontCreateCopyWithAttributes(font as CTFont, fontSize * scale, nil, nil)
        let metrics = TerminalCellMetrics(font: scaled, options: fontOptions)
        metricsCache = (scale, metrics)
        return metrics
    }

    /// Cell size in points. Both dimensions are whole device pixels, like
    /// Ghostty, so glyphs never straddle pixels on 1x or 2x displays.
    var cell: NSSize { metrics.pointSize(scale: backingScale) }

    init?(engine: TerminalEngine, view: MTKView) {
        guard let device = Self.device, let queue = device.makeCommandQueue(),
              let pipeline = Self.makePipeline(device: device, blending: true) else { return nil }
        self.engine = engine; self.queue = queue; self.view = view; self.pipeline = pipeline
        super.init()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        // MTKView's display link supplies presentation cadence. PTY throughput is
        // independent: invalidations only mark the latest terminal state dirty.
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.delegate = self
        engine.observers[observer] = { [weak self] in self?.requestDraw() }
    }

    // Keep Metal's NSError boundary outside the frame encoder. This also keeps
    // lazy pipeline compilation out of an active render pass during theme changes.
    @inline(never)
    private static func makePipeline(device: MTLDevice, blending: Bool) -> MTLRenderPipelineState? {
        if let cached = blending ? sharedPipeline : sharedBackgroundPipeline { return cached }
        guard let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "terminal_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "terminal_fragment")
        guard let color = descriptor.colorAttachments[0] else { return nil }
        color.pixelFormat = .bgra8Unorm
        // Everything is premultiplied: source over destination.
        color.isBlendingEnabled = blending
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        if blending { sharedPipeline = state } else { sharedBackgroundPipeline = state }
        return state
    }

    func detach() {
        presentation.cancel()
        updateTextBlink(hasBlinkingText: false, canPresent: false)
        engine.observers.removeValue(forKey: observer)
        view?.isPaused = true
        view?.delegate = nil
        // Committed command buffers retain their resources until GPU completion.
        buffers = [nil, nil, nil]
        backgrounds = []; foregrounds = []; contrastCache = [:]
        atlas = nil; atlasKey = nil
        displayedGraphics = TerminalGraphicsState(); imageDraws = []
        // The shared image cache remains bounded and can be reused by another
        // live view of the same terminal; command buffers retain in-flight textures.
    }

    // MARK: - Presentation

    func requestDraw() {
        guard !presentation.cancelled else { return }
        presentation.invalidate()
        guard let view else {
            updateTextBlink(hasBlinkingText: textBlink.hasBlinkingText, canPresent: false)
            return
        }
        guard canPresent(view) else {
            view.isPaused = true
            updateTextBlink(hasBlinkingText: textBlink.hasBlinkingText, canPresent: false)
            return
        }
        let refresh = view.window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        if view.preferredFramesPerSecond != refresh { view.preferredFramesPerSecond = refresh }
        if view.isPaused { view.isPaused = false }
    }

    private func canPresent(_ view: MTKView) -> Bool {
        view.bounds.width > 0 && view.bounds.height > 0 && !view.isHiddenOrHasHiddenAncestor
            && view.window?.occlusionState.contains(.visible) == true
    }

    private func updateTextBlink(hasBlinkingText: Bool, canPresent: Bool) {
        textBlink.update(hasBlinkingText: hasBlinkingText, canPresent: canPresent)
        guard textBlink.timerRequired, !presentation.cancelled else {
            textBlinkTimer?.invalidate()
            textBlinkTimer = nil
            return
        }
        guard textBlinkTimer == nil else { return }
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard !self.presentation.cancelled, let view = self.view, self.canPresent(view) else {
                    self.updateTextBlink(hasBlinkingText: self.textBlink.hasBlinkingText, canPresent: false)
                    return
                }
                if self.textBlink.advance() { self.requestDraw() }
            }
        }
        timer.tolerance = 0.06
        textBlinkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { requestDraw() }

    func draw(in view: MTKView) {
        guard !presentation.cancelled, canPresent(view) else {
            view.isPaused = true
            updateTextBlink(hasBlinkingText: textBlink.hasBlinkingText, canPresent: false)
            return
        }
        guard presentation.needsFrame || presentation.acquiringDrawable else {
            // MTKView tears down its CVDisplayLink on pause. Briefly retain it
            // across gaps in bursty output, without building or presenting frames.
            if presentation.shouldPauseDisplayLink(at: CACurrentMediaTime()) { view.isPaused = true }
            return
        }
        guard let layer = view.layer as? CAMetalLayer, let slot = presentation.beginAcquisition() else { return }
        // nextDrawable is documented to block until a display buffer is free.
        // Keep that wait away from the main thread and its lossless VT parser.
        let source = MetalDrawableSource(layer: layer)
        drawableQueue.async { [weak self, source] in
            autoreleasepool {
                let transfer = source.acquire()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.presentation.acquired()
                    guard !self.presentation.cancelled, let view = self.view, self.canPresent(view), let drawable = transfer.drawable else {
                        self.presentation.release(slot)
                        return
                    }
                    guard abs(CGFloat(drawable.texture.width) - view.drawableSize.width) < 1,
                          abs(CGFloat(drawable.texture.height) - view.drawableSize.height) < 1 else {
                        self.presentation.release(slot)
                        self.requestDraw()
                        return
                    }
                    self.render(in: view, texture: drawable.texture, drawable: drawable, slot: slot)
                }
            }
        }
    }

    // MARK: - Frame building

    private func render(in view: MTKView, texture: MTLTexture, drawable: CAMetalDrawable?, slot: Int) {
        var committed = false
        defer { if !committed { presentation.release(slot) } }
        // Commands retain textures until completion. Keeping this scratch list
        // afterwards would let hidden views pin images beyond the shared LRU.
        defer { imageDraws.removeAll(keepingCapacity: true) }
        let revision = presentation.requestedRevision
        guard view.bounds.width > 0, view.bounds.height > 0, texture.width > 0, texture.height > 0,
              let frame = engine.frame(), let cells = frame.cells, let device = Self.device else { return }
        onFrame?(frame)
        let scale = backingScale
        let theme = engine.theme
        guard let current = currentAtlas(device: device, scale: scale) else { return }
        let atlas = current.atlas
        let metrics = atlas.metrics
        let gridWidth = CGFloat(Int(frame.columns) * metrics.cellWidth) / scale
        let gridHeight = CGFloat(Int(frame.rows) * metrics.cellHeight) / scale
        let fit = interactive ? 1 : max(0.01, min(view.bounds.width / (gridWidth + 12), view.bounds.height / (gridHeight + 12)))
        let layout = GridLayout(metrics: metrics, scale: scale, fit: fit, inset: interactive ? Self.padding : 6 * fit)

        // Native full screen windows cannot be transparent on macOS.
        let opacity = view.window?.styleMask.contains(.fullScreen) == true ? 1 : theme.effectiveBackgroundOpacity
        configure(view.layer as? CAMetalLayer, opaque: opacity == 1)
        prepareImages(frame: frame, layout: layout, bounds: view.bounds, device: device)

        if geometryCapacity.resize(cells: frame.count) {
            // A large window or overview must not pin its peak geometry after
            // becoming a small pane. In-flight commands retain their buffers.
            backgrounds = []; foregrounds = []; buffers = [nil, nil, nil]
        }
        var builder = QuadBuilder(backgrounds: [], foregrounds: [], layout: layout)
        swap(&builder.backgrounds, &backgrounds)
        swap(&builder.foregrounds, &foregrounds)
        builder.backgrounds.removeAll(keepingCapacity: true)
        builder.foregrounds.removeAll(keepingCapacity: true)
        builder.backgrounds.reserveCapacity(frame.count)
        builder.foregrounds.reserveCapacity(frame.count)
        let hasBlinkingText = appendCells(frame: frame, cells: UnsafeBufferPointer(start: cells, count: frame.count),
                                          atlas: atlas, theme: theme, opacity: opacity, into: &builder)
        swap(&builder.backgrounds, &backgrounds)
        swap(&builder.foregrounds, &foregrounds)
        updateTextBlink(hasBlinkingText: hasBlinkingText, canPresent: true)

        guard encode(frame: frame, atlas: atlas, texture: texture, drawable: drawable, slot: slot, opacity: opacity,
                     theme: theme, layout: layout, device: device) else { return }
        committed = true
        presentation.submitted(revision: revision)
        // An atlas containing old scrollback glyphs may need one fresh pass.
        // If the visible glyph set itself cannot fit, endlessly retrying the
        // same frame consumes a CPU/GPU core without adding any content.
        if atlas.full && !current.replacedFull { requestDraw() }
    }

    /// The atlas for the current font and scale, replacing an exhausted one.
    /// Also reports whether this call replaced an exhausted atlas.
    private func currentAtlas(device: MTLDevice, scale: CGFloat) -> (atlas: GlyphAtlas, replacedFull: Bool)? {
        let key = AtlasKey(font: font.fontName, size: fontSize, scale: scale, options: fontOptions)
        let replacingFull = atlasKey == key && atlas?.full == true
        if atlasKey != key || atlas == nil || replacingFull {
            let font = self.font, options = fontOptions
            atlas = Self.atlases.resource(for: key, usable: { !$0.full }) {
                GlyphAtlas(device: device, font: font, scale: scale, options: options)
            }
            atlasKey = key
        }
        return atlas.map { ($0, replacingFull) }
    }

    private func configure(_ layer: CAMetalLayer?, opaque: Bool) {
        guard let layer else { return }
        if layer.isOpaque != opaque { layer.isOpaque = opaque }
        // Keep the last frame anchored while a resize waits for the next one,
        // rather than stretching every glyph.
        if layer.contentsGravity != .topLeft { layer.contentsGravity = .topLeft }
        let name = fontOptions.colorspace == .displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        if layer.colorspace?.name != name { layer.colorspace = CGColorSpace(name: name) }
    }

    /// Builds cell backgrounds, glyphs, decorations and the cursor. Returns
    /// whether any visible text blinks.
    private func appendCells(frame: ILFrame, cells: UnsafeBufferPointer<ILCell>, atlas: GlyphAtlas, theme: TerminalTheme,
                             opacity: Double, into builder: inout QuadBuilder) -> Bool {
        let layout = builder.layout, metrics = layout.metrics
        let columns = Int(frame.columns)
        let cursorVisible = frame.cursorVisible && (!frame.cursorBlinking || cursorOn || !focused)
        let cursorIndex = Int(frame.cursorRow) * columns + Int(frame.cursorColumn)
        let cursorWidth = cursorIndex < cells.count ? max(1, Int(cells[cursorIndex].width)) : 1
        let blockCursor = cursorVisible && focused && frame.cursorShape == .block
        let shapingCursor = cursorVisible ? TerminalTextRuns.Cursor(row: frame.cursorRow, column: frame.cursorColumn) : nil
        // Keep a run's bitmap, including its overhang padding, within the atlas.
        let shapingColumns = max(2, min(64, GlyphAtlas.dimension / metrics.cellWidth - 2))
        let minimumContrast = theme.minimumContrast ?? 4.5
        if contrastTarget != theme.foreground || contrastMinimum != minimumContrast {
            contrastCache.removeAll(keepingCapacity: true)
            contrastTarget = theme.foreground
            contrastMinimum = minimumContrast
        }
        var contrastMemo: (foreground: UInt32, background: UInt32, result: UInt32)?
        var hasBlinkingText = false

        func coversCursor(_ cell: ILCell) -> Bool {
            cursorVisible && cell.row == frame.cursorRow && cell.column == frame.cursorColumn
        }

        var index = 0
        while index < cells.count {
            defer { index += 1 }
            let cell = cells[index]
            let flags = cell.styleFlags, attributes = cell.styleAttributes

            // Contextual scripts and ASCII operator ligatures shape several cells at once.
            var runText: String?
            var runClusters: [TerminalTextRuns.Cluster] = []
            var span = 1
            if let run = TerminalTextRuns.plan(cells, at: index, cursor: shapingCursor, maximumColumns: shapingColumns) {
                runText = run.text; runClusters = run.clusters; span = run.columns
                index += run.cellCount - 1
            } else if let operatorRun = operatorRun(cells, at: index, cursorCovers: coversCursor) {
                runText = operatorRun.text; span = operatorRun.count
                index += span - 1
            }

            let rect = layout.cellRect(column: Int(cell.column), row: Int(cell.row), columns: span)
            var background = cell.background, foreground = cell.foreground
            func resolved(_ color: TerminalThemeColor) -> UInt32 {
                color.resolve(foreground: cell.foreground, background: cell.background,
                              windowForeground: frame.foreground, windowBackground: frame.background)
            }
            if flags.contains(.selected) {
                background = theme.selectionBackground.map(resolved) ?? theme.accent
                foreground = theme.selectionForeground.map(resolved) ?? (theme.isLight ? 0xffffff : 0x15191f)
            } else if flags.contains(.searchSelected) {
                background = SearchColors.selectedBackground; foreground = SearchColors.selectedForeground
            } else if flags.contains(.searchMatch) {
                background = SearchColors.matchBackground; foreground = SearchColors.matchForeground
            }
            let underCursor = blockCursor && cell.row == frame.cursorRow
                && Int(cell.column) >= Int(frame.cursorColumn) && Int(cell.column) < Int(frame.cursorColumn) + cursorWidth

            // Highlights and inverse video stay opaque in translucent windows.
            let opaqueCell = !flags.isDisjoint(with: .highlights) || attributes.contains(.inverse)
            if background != frame.background || (opacity < 1 && (opaqueCell || attributes.contains(.explicitBackground))) {
                let alpha = !opaqueCell && theme.backgroundOpacityCells == true ? Float(opacity) : 1
                builder.background(rect, background, alpha: alpha)
            }
            if underCursor {
                background = theme.cursorColor.map(resolved) ?? frame.cursorColor
                foreground = theme.cursorText.map(resolved) ?? frame.background
            }
            // Spacer cells of wide characters draw only their background.
            if cell.width == 0 { continue }
            let hasDecorations = !flags.isDisjoint(with: .decorations)
            if attributes.contains(.blink) && !attributes.contains(.invisible) && (!cell.isBlank || hasDecorations) {
                hasBlinkingText = true
            }
            guard textBlink.drawsText(invisible: attributes.contains(.invisible), blinking: attributes.contains(.blink)) else { continue }

            let scalar = cell.firstScalar
            // Pixel-art programs use block elements as colored geometry. Font
            // metrics, contrast remapping and atlas bitmaps would all corrupt them.
            if runText == nil, TerminalBlockElements.range.contains(scalar), cell.isSingleScalar {
                let alpha = TerminalBlockElements.alpha(scalar)
                for part in TerminalBlockElements.rects(scalar) {
                    builder.solid(CGRect(x: rect.minX + part.minX * rect.width, y: rect.minY + part.minY * rect.height,
                                         width: part.width * rect.width, height: part.height * rect.height), foreground, alpha: alpha)
                }
                if hasDecorations { builder.decorations(cell, in: rect, foreground: foreground) }
                continue
            }

            let drawsGlyph = runText != nil || !cell.isBlank
            if contrastCorrection && (drawsGlyph || hasDecorations) && !TerminalCellDrawing.isGraphicsElement(scalar) {
                if let memo = contrastMemo, memo.foreground == foreground, memo.background == background {
                    foreground = memo.result
                } else {
                    let result = corrected(foreground, against: background, minimumContrast: minimumContrast)
                    contrastMemo = (foreground, background, result)
                    foreground = result
                }
            }
            if drawsGlyph, let entry = glyph(for: cell, scalar: scalar, runText: runText, clusters: runClusters, span: span,
                                              index: index, cells: cells, columns: columns, atlas: atlas), !entry.isEmpty {
                builder.glyph(entry, cell: rect, color: foreground)
            }
            if hasDecorations {
                let columns = span == 1 ? max(1, Int(cell.width)) : span
                builder.decorations(cell, in: layout.cellRect(column: Int(cell.column), row: Int(cell.row), columns: columns),
                                    foreground: foreground)
            }
        }

        if cursorVisible {
            appendCursor(frame: frame, cells: cells, index: cursorIndex, width: cursorWidth, theme: theme, into: &builder)
        }
        return hasBlinkingText
    }

    private func glyph(for cell: ILCell, scalar: UInt32, runText: String?, clusters: [TerminalTextRuns.Cluster], span: Int,
                       index: Int, cells: UnsafeBufferPointer<ILCell>, columns: Int, atlas: GlyphAtlas) -> GlyphAtlas.Entry? {
        let flags = cell.styleFlags
        let style = TerminalFontRasterizer.Style().union(flags.contains(.bold) ? .bold : []).union(flags.contains(.italic) ? .italic : [])
        if runText == nil && scalar < 0x80 && cell.width == 1 && cell.isSingleScalar {
            return atlas.asciiGlyph(UInt8(scalar), style: style)
        }
        var key = TerminalFontRasterizer.Key(text: runText ?? cell.string, bold: flags.contains(.bold), italic: flags.contains(.italic),
                                             width: max(span, Int(cell.width)))
        key.clusters = clusters
        // A lone Nerd Font icon may grow into a following blank cell, as in
        // Ghostty. Adjacent icons keep a single-cell constraint.
        if cell.width == 1 && TerminalFontRasterizer.isPrivateUse(scalar) && !TerminalCellDrawing.isGraphicsElement(scalar),
           index + 1 < cells.count, Int(cell.column) + 1 < columns, cells[index + 1].isBlank {
            let previous = cell.column > 0 && index > 0 ? cells[index - 1].firstScalar : 0
            let previousIsIcon = TerminalFontRasterizer.isPrivateUse(previous) && !TerminalCellDrawing.isGraphicsElement(previous)
            if !previousIsIcon { key.constraintColumns = 2 }
        }
        return atlas.glyph(key)
    }

    /// ASCII symbols that code fonts join into ligatures, such as `=>`,
    /// `!==`, `#{` and `__`. Letters stay on the per-cell fast path.
    private static let ligatureSymbols: [Bool] = {
        var table = [Bool](repeating: false, count: 128)
        for byte in "!#%&()*+-./:;<=>?[]^_{|}~".utf8 { table[Int(byte)] = true }
        return table
    }()

    /// Adjacent, identically styled ligature symbols shape together.
    private func operatorRun(_ cells: UnsafeBufferPointer<ILCell>, at start: Int, cursorCovers: (ILCell) -> Bool) -> (text: String, count: Int)? {
        let first = cells[start]
        func isOperator(_ cell: ILCell) -> Bool {
            cell.width == 1 && cell.text.1 == 0 && cell.text.0 > 0 && Self.ligatureSymbols[Int(cell.text.0)] && !cursorCovers(cell)
        }
        guard isOperator(first), start + 1 < cells.count else { return nil }
        operatorBytes.removeAll(keepingCapacity: true)
        operatorBytes.append(UInt8(bitPattern: first.text.0))
        while operatorBytes.count < Self.maximumOperatorRun && start + operatorBytes.count < cells.count {
            let next = cells[start + operatorBytes.count]
            guard next.row == first.row, Int(next.column) == Int(first.column) + operatorBytes.count,
                  TerminalTextRuns.sameStyle(first, next), isOperator(next) else { break }
            operatorBytes.append(UInt8(bitPattern: next.text.0))
        }
        guard operatorBytes.count > 1 else { return nil }
        return (String(decoding: operatorBytes, as: UTF8.self), operatorBytes.count)
    }

    /// Bar, underline and hollow cursors follow Ghostty's sprites: the bar
    /// straddles the cell's left edge and full-height cursors keep the font's
    /// natural height, centered in an adjusted cell. The block cursor is drawn
    /// behind the cell's text, which the cell loop recolors.
    private func appendCursor(frame: ILFrame, cells: UnsafeBufferPointer<ILCell>, index: Int, width: Int, theme: TerminalTheme,
                              into builder: inout QuadBuilder) {
        let layout = builder.layout, metrics = layout.metrics, pixel = layout.pixel
        let cursorCell = index < cells.count ? cells[index] : nil
        let color = theme.cursorColor?.resolve(foreground: cursorCell?.foreground ?? frame.foreground,
                                               background: cursorCell?.background ?? frame.background,
                                               windowForeground: frame.foreground, windowBackground: frame.background) ?? frame.cursorColor
        let cell = layout.cellRect(column: Int(frame.cursorColumn), row: Int(frame.cursorRow), columns: width)
        let full = CGRect(x: cell.minX, y: cell.minY + CGFloat(metrics.cursorTop) * pixel, width: cell.width,
                          height: CGFloat(metrics.cursorHeight) * pixel)
        let thickness = CGFloat(metrics.cursorThickness) * pixel
        let style: TerminalCursorStyle = focused ? frame.cursorShape : .blockHollow
        switch style {
        case .block:
            builder.background(full, color)
        case .bar:
            let offset = CGFloat((metrics.cursorThickness + 1) / 2) * pixel
            builder.solid(CGRect(x: full.minX - offset, y: full.minY, width: thickness, height: full.height), color)
        case .underline:
            let top = min(metrics.underlinePosition, metrics.cellHeight + metrics.cellHeight / 4 - metrics.underlineThickness)
            builder.solid(layout.stroke(in: cell, top: top, height: metrics.cursorThickness), color)
        case .blockHollow:
            // Previews show no cursor unless they hold focus.
            guard interactive || focused else { return }
            builder.solid(CGRect(x: full.minX, y: full.minY, width: full.width, height: thickness), color)
            builder.solid(CGRect(x: full.minX, y: full.maxY - thickness, width: full.width, height: thickness), color)
            builder.solid(CGRect(x: full.minX, y: full.minY, width: thickness, height: full.height), color)
            builder.solid(CGRect(x: full.maxX - thickness, y: full.minY, width: thickness, height: full.height), color)
        }
    }

    /// Selects the image placements to draw this frame. Image updates obey
    /// synchronized output just like text.
    private func prepareImages(frame: ILFrame, layout: GridLayout, bounds: CGRect, device: MTLDevice) {
        imageDraws.removeAll(keepingCapacity: true)
        guard !engine.graphics.placements.isEmpty || !displayedGraphics.placements.isEmpty || graphicsNamespace != nil else { return }
        let namespace = engine.blockID + ":" + (engine.replayID ?? engine.stream ?? "local")
        if namespace != graphicsNamespace {
            displayedGraphics = TerminalGraphicsState()
            if let old = graphicsNamespace { Self.imageTextures.prune(namespace: old, images: [:]) }
            graphicsNamespace = namespace
        }
        // Keep the last submitted scene until a synchronized-output hold ends or expires.
        if il_terminal_render_hold_remaining(engine.handle) <= 0 { displayedGraphics = engine.graphics }
        guard !displayedGraphics.placements.isEmpty else {
            Self.imageTextures.prune(namespace: namespace, images: [:])
            graphicsNamespace = nil
            return
        }
        Self.imageTextures.prune(namespace: namespace, images: displayedGraphics.images)
        let cell = CGSize(width: CGFloat(layout.metrics.cellWidth) / layout.scale, height: CGFloat(layout.metrics.cellHeight) / layout.scale)
        for placement in displayedGraphics.placements {
            guard let image = displayedGraphics.images[placement.imageID],
                  let quad = Self.imageQuad(placement: placement, image: image, scene: displayedGraphics, frame: frame,
                                            cell: cell, fit: layout.fit, inset: layout.inset, bounds: bounds),
                  let texture = Self.imageTextures.texture(device: device, namespace: namespace, image: image) else { continue }
            imageDraws.append(ImageDraw(quad: quad, texture: texture, z: placement.z))
        }
    }

    // MARK: - Encoding

    private func encode(frame: ILFrame, atlas: GlyphAtlas, texture: MTLTexture, drawable: CAMetalDrawable?, slot: Int, opacity: Double,
                        theme: TerminalTheme, layout: GridLayout, device: MTLDevice) -> Bool {
        let quadCount = backgrounds.count + foregrounds.count
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let clear = premultiplied(frame.background, alpha: Float(opacity))
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(clear.x), green: Double(clear.y), blue: Double(clear.z), alpha: Double(clear.w))
        // Translucent explicit backgrounds replace the clear color. Blending
        // them over it would apply opacity twice (0.5 -> 0.75).
        let replaceBackgrounds = opacity < 1 && theme.backgroundOpacityCells == true && !backgrounds.isEmpty
            && !imageDraws.contains { ImageLayer.belowBackgrounds($0.z) }
        let backgroundPipeline = replaceBackgrounds ? Self.makePipeline(device: device, blending: false) : pipeline
        // A failed shader cannot leave a half-configured pass or acknowledge a
        // frame that was not drawn. A later invalidation can retry construction.
        guard let backgroundPipeline, let command = queue.makeCommandBuffer() else { return false }
        let required = max(64, quadCount * MemoryLayout<TerminalQuad>.stride)
        if (buffers[slot]?.length ?? 0) < required { buffers[slot] = device.makeBuffer(length: required * 2, options: .storageModeShared) }
        guard let buffer = buffers[slot], let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        backgrounds.withUnsafeBytes { if let base = $0.baseAddress { buffer.contents().copyMemory(from: base, byteCount: $0.count) } }
        foregrounds.withUnsafeBytes {
            if let base = $0.baseAddress {
                buffer.contents().advanced(by: backgrounds.count * MemoryLayout<TerminalQuad>.stride).copyMemory(from: base, byteCount: $0.count)
            }
        }

        // Drawable dimensions are integral. Using fractional point bounds here
        // stretches every glyph slightly when a split lands between pixels.
        var uniforms = TerminalUniforms(viewport: SIMD2(Float(CGFloat(texture.width) / layout.scale), Float(CGFloat(texture.height) / layout.scale)),
                                        cellWidth: Float(layout.metrics.cellWidth), smoothGlyphs: interactive ? 0 : 1)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TerminalUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TerminalUniforms>.stride, index: 1)
        // Every declared texture needs a binding; the grayscale atlas stands in.
        encoder.setFragmentTexture(atlas.grayscale, index: 0)
        encoder.setFragmentTexture(atlas.color ?? atlas.grayscale, index: 1)
        encoder.setFragmentTexture(atlas.grayscale, index: 2)

        func drawImages(where layer: (Int32) -> Bool) {
            var drew = false
            for draw in imageDraws where layer(draw.z) {
                var quad = draw.quad
                encoder.setVertexBytes(&quad, length: MemoryLayout<TerminalQuad>.stride, index: 0)
                encoder.setFragmentTexture(draw.texture, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
                drew = true
            }
            if drew { encoder.setVertexBuffer(buffer, offset: 0, index: 0) }
        }
        drawImages(where: ImageLayer.belowBackgrounds)
        if !backgrounds.isEmpty {
            encoder.setRenderPipelineState(backgroundPipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: backgrounds.count)
            encoder.setRenderPipelineState(pipeline)
        }
        drawImages(where: ImageLayer.belowText)
        if !foregrounds.isEmpty {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: foregrounds.count, baseInstance: backgrounds.count)
        }
        drawImages(where: ImageLayer.aboveText)
        encoder.endEncoding()
        if let drawable {
            command.present(drawable)
            if interactive && engine.stream != nil { LaunchMetrics.firstTerminalFrame(drawable: drawable) }
        }
        command.addCompletedHandler { [weak self] completed in
            let failed = completed.status == .error
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.presentation.release(slot)
                if failed { self.requestDraw() }
            }
        }
        command.commit()
        return true
    }

    private static func imageQuad(placement: WireGraphicsPlacement, image: WireGraphicsImage, scene: TerminalGraphicsState,
                                  frame: ILFrame, cell: CGSize, fit: CGFloat, inset: CGFloat, bounds: CGRect) -> TerminalQuad? {
        guard placement.pixelWidth > 0, placement.pixelHeight > 0, placement.sourceWidth > 0, placement.sourceHeight > 0 else { return nil }
        let xScale = cell.width * fit / CGFloat(scene.cellWidth), yScale = cell.height * fit / CGFloat(scene.cellHeight)
        // Placement rows count from the bottom of history, so restoring more
        // scrollback cannot move an image.
        let row = Double(frame.scrollTotal) - Double(frame.rows) + Double(placement.row) - Double(frame.scrollOffset)
        let destination = CGRect(x: inset + CGFloat(placement.column) * cell.width * fit + CGFloat(placement.xOffset) * xScale,
                                 y: inset + CGFloat(row) * cell.height * fit + CGFloat(placement.yOffset) * yScale,
                                 width: CGFloat(placement.pixelWidth) * xScale, height: CGFloat(placement.pixelHeight) * yScale)
        let viewport = CGRect(x: inset, y: inset, width: CGFloat(frame.columns) * cell.width * fit,
                              height: CGFloat(frame.rows) * cell.height * fit).intersection(bounds)
        let clipped = destination.intersection(viewport)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let sourceWidth = CGFloat(placement.sourceWidth) / CGFloat(image.width)
        let sourceHeight = CGFloat(placement.sourceHeight) / CGFloat(image.height)
        let uv = SIMD4(Float(CGFloat(placement.sourceX) / CGFloat(image.width) + (clipped.minX - destination.minX) / destination.width * sourceWidth),
                       Float(CGFloat(placement.sourceY) / CGFloat(image.height) + (clipped.minY - destination.minY) / destination.height * sourceHeight),
                       Float(clipped.width / destination.width * sourceWidth), Float(clipped.height / destination.height * sourceHeight))
        return TerminalQuad(rect: SIMD4(Float(clipped.minX), Float(clipped.minY), Float(clipped.width), Float(clipped.height)),
                            uv: uv, color: SIMD4(repeating: 1), kind: .image)
    }

    private func corrected(_ foreground: UInt32, against background: UInt32, minimumContrast: Double) -> UInt32 {
        let key = UInt64(foreground) << 32 | UInt64(background)
        if let cached = contrastCache[key] { return cached }
        let result = ContrastCorrection.correct(foreground, background: background, target: engine.theme.foreground, minimumContrast: minimumContrast)
        if contrastCache.count > 8_192 { contrastCache.removeAll(keepingCapacity: true) }
        contrastCache[key] = result
        return result
    }
}
