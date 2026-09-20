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

private struct TerminalQuad {
    var rect: SIMD4<Float>
    var uv: SIMD4<Float>
    var color: SIMD4<Float>
    var textured: UInt32
    // Metal arrays stride by 64 bytes. Explicit storage also makes a single
    // stack quad safe to upload at that length (Swift's unpadded size is 52).
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
    var padding2: UInt32 = 0
}

@MainActor
private final class TerminalImageTextureCache {
    struct Key: Hashable { let namespace: String; let id: UInt32; let generation: UInt64 }
    private struct Entry { let texture: MTLTexture; let cost: Int; var used: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var byteCount = 0
    var count: Int { entries.count }
    let byteLimit: Int

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
        if var entry = entries[key] { entry.used = clock; entries[key] = entry; return entry.texture }
        let width = Int(image.width), height = Int(image.height)
        guard width > 0, height > 0, width <= 16_384, height <= 16_384, width * height * 4 <= byteLimit else { return nil }
        let components: Int
        switch image.format { case 0: components = 3; case 1: components = 4; case 3: components = 2; case 4: components = 1; default: return nil }
        guard image.data.count == width * height * components else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), texture.allocatedSize <= byteLimit else { return nil }
        let region = MTLRegionMake2D(0, 0, width, height)
        if components == 4 {
            image.data.withUnsafeBytes { texture.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        } else {
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            image.data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                for pixel in 0..<(width * height) {
                    let input = pixel * components, output = pixel * 4
                    rgba[output] = source[input]
                    rgba[output + 1] = components == 3 ? source[input + 1] : source[input]
                    rgba[output + 2] = components == 3 ? source[input + 2] : source[input]
                    if components == 2 { rgba[output + 3] = source[input + 1] }
                }
            }
            rgba.withUnsafeBytes { texture.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        }
        // A retransmission with the same image ID is new content even when its
        // size is unchanged. Drop its obsolete texture before LRU eviction.
        for old in entries.keys where old.namespace == namespace && old.id == image.id { remove(old) }
        while byteCount + texture.allocatedSize > byteLimit || entries.count >= 1_024 {
            guard let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key else { break }
            remove(oldest)
        }
        entries[key] = Entry(texture: texture, cost: texture.allocatedSize, used: clock)
        byteCount += texture.allocatedSize
        return texture
    }
}

@MainActor
private final class GlyphAtlas {
    typealias Key = TerminalFontRasterizer.Key
    struct Entry { let rect: CGRect; let padding: Int; let colored: Bool }
    let device: MTLDevice
    let font: NSFont
    let scale: CGFloat
    let cell: NSSize
    private(set) var texture: MTLTexture
    private var entries: [Key: Entry] = [:]
    private let rasterizer: TerminalFontRasterizer
    private var x = 0, y = 0, lineHeight = 0
    var full = false
    private let dimension = 2048

    init(device: MTLDevice, font: NSFont, scale: CGFloat, cell: NSSize, options: TerminalFontOptions) {
        self.device = device; self.font = font; self.scale = scale; self.cell = cell
        rasterizer = TerminalFontRasterizer(font: font, scale: scale, cell: cell, options: options)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2048, height: 2048, mipmapped: false)
        descriptor.usage = .shaderRead; descriptor.storageMode = .shared
        texture = device.makeTexture(descriptor: descriptor)!
    }

    func glyph(_ key: Key) -> Entry? {
        if let cached = entries[key] { return cached }
        // Once capacity is exhausted, misses cannot fit. Avoid repeatedly
        // shaping and rasterizing them before the atlas is replaced.
        guard !full else { return nil }
        guard let bitmap = rasterizer.rasterize(key) else { return nil }
        let width = bitmap.width, height = bitmap.height
        guard width < dimension, height < dimension else { full = true; return nil }
        if x + width >= dimension { x = 0; y += lineHeight + 1; lineHeight = 0 }
        guard y + height < dimension else { full = true; return nil }
        bitmap.bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(x, y, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        let entry = Entry(rect: rect, padding: bitmap.padding, colored: bitmap.colored)
        entries[key] = entry; x += width + 1; lineHeight = max(lineHeight, height)
        return entry
    }
}

@MainActor
final class MetalTerminalRenderer: NSObject, MTKViewDelegate {
    static let device = MTLCreateSystemDefaultDevice()
    private struct AtlasKey: Hashable { let font: String; let size: CGFloat; let scale: CGFloat; let width: CGFloat; let height: CGFloat; let options: TerminalFontOptions }
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
    private var geometryCapacity = TerminalGeometryCapacity()
    private var atlas: GlyphAtlas?
    private var atlasKey: AtlasKey?
    private let drawableQueue = DispatchQueue(label: "illogical.metal.drawable", qos: .userInteractive)
    private var presentation = TerminalPresentationState()
    private var textBlink = TerminalTextBlinkState()
    private var textBlinkTimer: Timer?
    weak var view: MTKView?
    var fontSize: CGFloat = 13 { didSet { if fontSize != oldValue { invalidateFont() } } }
    var fontName = "SF Mono" { didSet { if fontName != oldValue { invalidateFont() } } }
    var fontOptions = TerminalFontOptions.defaults { didSet { if fontOptions != oldValue { invalidateFont() } } }
    var focused = false
    var interactive = true
    var contrastCorrection = true
    var cursorOn = true
    var onFrame: ((ILFrame) -> Void)?
    private var contrastCache: [UInt64: UInt32] = [:]
    private var contrastTarget: UInt32?
    private var contrastMinimum: Double?
    private var fontCache: NSFont?
    private var cellCache: NSSize?
    private var displayedGraphics = TerminalGraphicsState()
    private var graphicsNamespace: String?
    private var imageDraws: [(quad: TerminalQuad, texture: MTLTexture, z: Int32)] = []

    private func invalidateFont() {
        fontCache = nil; cellCache = nil; atlas = nil; atlasKey = nil
    }

    var font: NSFont {
        if let cached = fontCache { return cached }
        let base = NSFont(name: fontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let resolved = TerminalFontRasterizer.configuredFont(base as CTFont, options: fontOptions) as NSFont
        fontCache = resolved
        return resolved
    }
    var cell: NSSize {
        if let cached = cellCache { return cached }
        let f = font
        let width = ("M" as NSString).size(withAttributes: [.font: f]).width
        let result = NSSize(width: ceil(width * 2) / 2, height: ceil(f.ascender - f.descender + f.leading + 3))
        cellCache = result
        return result
    }

    init?(engine: TerminalEngine, view: MTKView) {
        guard let device = Self.device, let queue = device.makeCommandQueue() else { return nil }
        self.engine = engine; self.queue = queue; self.view = view
        guard let state = Self.makePipeline(device: device, blending: true) else { return nil }
        pipeline = state
        super.init()
        view.device = device; view.colorPixelFormat = .bgra8Unorm; view.framebufferOnly = true
        // MTKView's display link supplies presentation cadence. PTY throughput is
        // independent: invalidations only mark the latest terminal state dirty.
        view.isPaused = true; view.enableSetNeedsDisplay = false; view.delegate = self
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
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm; color.isBlendingEnabled = blending
        color.sourceRGBBlendFactor = .one; color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha; color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        if blending { sharedPipeline = state } else { sharedBackgroundPipeline = state }
        return state
    }

    func detach() {
        presentation.cancel()
        updateTextBlink(hasBlinkingText: false, canPresent: false)
        engine.observers.removeValue(forKey: observer)
        view?.isPaused = true; view?.delegate = nil
        // Committed command buffers retain their resources until GPU completion.
        buffers = [nil, nil, nil]
        backgrounds = []; foregrounds = []; contrastCache = [:]
        atlas = nil; atlasKey = nil
        displayedGraphics = TerminalGraphicsState(); imageDraws = []
        // The shared cache remains bounded and can be reused by another live
        // view of the same terminal; command buffers retain in-flight textures.
    }

    func requestDraw() {
        guard !presentation.cancelled else { return }
        presentation.invalidate()
        guard let view else { updateTextBlink(hasBlinkingText: textBlink.hasBlinkingText, canPresent: false); return }
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
            textBlinkTimer?.invalidate(); textBlinkTimer = nil
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
                    guard abs(CGFloat(drawable.texture.width) - view.drawableSize.width) < 1, abs(CGFloat(drawable.texture.height) - view.drawableSize.height) < 1 else {
                        self.presentation.release(slot)
                        self.requestDraw()
                        return
                    }
                    self.render(in: view, texture: drawable.texture, drawable: drawable, slot: slot)
                }
            }
        }
    }

    private func render(in view: MTKView, texture: MTLTexture, drawable: CAMetalDrawable?, slot: Int) {
        var committed = false
        defer { if !committed { presentation.release(slot) } }
        // Commands retain textures until completion. Keeping this scratch list
        // afterwards would let hidden views pin images beyond the shared LRU.
        defer { imageDraws.removeAll(keepingCapacity: true) }
        let revision = presentation.requestedRevision
        guard view.bounds.width > 0, view.bounds.height > 0, let frame = engine.frame(), let cells = frame.cells, let device = Self.device else { return }
        onFrame?(frame)
        let scale = view.window?.backingScaleFactor ?? 2
        let cell = self.cell
        let font = self.font
        let theme = engine.theme
        let minimumContrast = theme.minimumContrast ?? 4.5
        if contrastTarget != theme.foreground || contrastMinimum != minimumContrast {
            contrastCache.removeAll(keepingCapacity: true); contrastTarget = theme.foreground; contrastMinimum = minimumContrast
        }
        // Native full screen windows cannot be transparent on macOS.
        let opacity = view.window?.styleMask.contains(.fullScreen) == true ? 1 : theme.effectiveBackgroundOpacity
        if let layer = view.layer as? CAMetalLayer, layer.isOpaque != (opacity == 1) { layer.isOpaque = opacity == 1 }
        let key = AtlasKey(font:font.fontName,size:fontSize,scale:scale,width:cell.width,height:cell.height,options:fontOptions)
        let replacingFullAtlas = atlasKey == key && atlas?.full == true
        if atlasKey != key || atlas == nil || replacingFullAtlas {
            atlas = Self.atlases.resource(for: key, usable: { !$0.full }) {
                GlyphAtlas(device: device, font: font, scale: scale, cell: cell, options: fontOptions)
            }
            atlasKey = key
        }
        guard let atlas else { return }
        let fit = interactive ? CGFloat(1) : min(view.bounds.width / (CGFloat(frame.columns) * cell.width + 12), view.bounds.height / (CGFloat(frame.rows) * cell.height + 12))
        let inset: CGFloat = interactive ? 8 : 6 * fit
        if !engine.graphics.placements.isEmpty || !displayedGraphics.placements.isEmpty || graphicsNamespace != nil {
        let namespace = engine.blockID + ":" + (engine.replayID ?? engine.stream ?? "local")
        if namespace != graphicsNamespace {
            displayedGraphics = TerminalGraphicsState()
            if let old = graphicsNamespace { Self.imageTextures.prune(namespace: old, images: [:]) }
            graphicsNamespace = namespace
        }
        // Image side-channel updates must obey synchronized output just like
        // text. Keep the last submitted scene until the hold ends or expires.
        if il_terminal_render_hold_remaining(engine.handle) <= 0 { displayedGraphics = engine.graphics }
        imageDraws.removeAll(keepingCapacity: true)
        if !displayedGraphics.placements.isEmpty {
            Self.imageTextures.prune(namespace: namespace, images: displayedGraphics.images)
            for placement in displayedGraphics.placements {
                guard let image = displayedGraphics.images[placement.imageID],
                      let quad = Self.imageQuad(placement: placement, image: image, scene: displayedGraphics, frame: frame,
                        cell: cell, fit: fit, inset: inset, bounds: view.bounds),
                      let texture = Self.imageTextures.texture(device: device, namespace: namespace, image: image) else { continue }
                imageDraws.append((quad, texture, placement.z))
            }
        } else {
            Self.imageTextures.prune(namespace: namespace, images: [:])
            graphicsNamespace = nil
        }
        }
        let drawCursor = frame.cursorVisible && (!frame.cursorBlinking || cursorOn || !focused)
        let cursorIndex = Int(frame.cursorRow) * Int(frame.columns) + Int(frame.cursorColumn)
        let cursorWidth = cursorIndex < frame.count ? max(1,Int(cells[cursorIndex].width)) : 1
        if geometryCapacity.resize(cells: frame.count) {
            // A large window or overview must not pin its peak geometry after
            // becoming a small pane. In-flight commands retain their buffers.
            backgrounds = []; foregrounds = []; buffers = [nil, nil, nil]
        }
        backgrounds.removeAll(keepingCapacity: true); foregrounds.removeAll(keepingCapacity: true)
        backgrounds.reserveCapacity(frame.count); foregrounds.reserveCapacity(frame.count)
        func quad(_ rect: CGRect, _ color: UInt32, alpha: Float = 1) -> TerminalQuad {
            TerminalQuad(rect: SIMD4(Float(rect.minX),Float(rect.minY),Float(rect.width),Float(rect.height)), uv: .zero, color: Self.rgba(color,alpha:alpha), textured: 0)
        }
        func decorations(_ data: ILCell, rect: CGRect, foreground: UInt32, span: Int) {
            let width = rect.width * CGFloat(span == 1 ? max(1, Int(data.width)) : 1)
            if data.underlineStyle != 0 {
                let color = data.attributes & 1 != 0 ? data.underlineColor : foreground
                if data.underlineStyle == 1 || data.underlineStyle == 2 {
                    foregrounds.append(quad(CGRect(x: rect.minX, y: rect.maxY - 2 * fit, width: width, height: fit), color))
                    if data.underlineStyle == 2 {
                        foregrounds.append(quad(CGRect(x: rect.minX, y: rect.maxY - 4 * fit, width: width, height: fit), color))
                    }
                } else {
                    let height: CGFloat = data.underlineStyle == 3 ? 3 : (data.underlineStyle == 4 ? 1.5 : 1)
                    let bottomInset: CGFloat = data.underlineStyle == 3 ? 4 : 2
                    var line = quad(CGRect(x: rect.minX, y: rect.maxY - bottomInset * fit, width: width, height: height * fit), color)
                    line.textured = UInt32(data.underlineStyle) + 2
                    // Logical terminal coordinates preserve phase across cells
                    // and scale the pattern consistently in overview previews.
                    line.uv = SIMD4(Float(CGFloat(data.column) * cell.width), 0, Float(width / fit), Float(height))
                    foregrounds.append(line)
                }
            }
            if data.flags & 16 != 0 { foregrounds.append(quad(CGRect(x: rect.minX, y: rect.midY, width: width, height: fit), foreground)) }
            if data.flags & 32 != 0 { foregrounds.append(quad(CGRect(x: rect.minX, y: rect.minY, width: width, height: fit), foreground)) }
        }
        var index = 0
        var hasBlinkingText = false
        let cellBuffer = UnsafeBufferPointer(start: cells, count: frame.count)
        let shapingCursor = drawCursor ? TerminalTextRuns.Cursor(row: frame.cursorRow, column: frame.cursorColumn) : nil
        let shapingColumns = max(2, min(64, Int((2048 - 4 * ceil(scale) - 1) / (cell.width * scale))))
        while index < frame.count {
            defer { index += 1 }
            var cellData = cells[index]
            var operatorText: String?
            var textClusters: [TerminalTextRuns.Cluster] = []
            var span = 1
            if let run = TerminalTextRuns.plan(cellBuffer, at: index, cursor: shapingCursor, maximumColumns: shapingColumns) {
                operatorText = run.text; textClusters = run.clusters; span = run.columns
                index += run.cellCount - 1
            } else if cellData.width == 1 && Self.isLigatureOperator(cellData.text.0) && cellData.text.1 == 0,
               !(drawCursor && frame.cursorRow == cellData.row && frame.cursorColumn == cellData.column) {
                var text = [UInt8(bitPattern: cellData.text.0)]
                while span < 24 && index + span < frame.count {
                    let next = cells[index + span]
                    guard next.width == 1, next.row == cellData.row, next.column == cellData.column + UInt16(span),
                          next.foreground == cellData.foreground, next.background == cellData.background, next.flags == cellData.flags,
                          next.underlineStyle == cellData.underlineStyle, next.underlineColor == cellData.underlineColor, next.attributes == cellData.attributes,
                          Self.isLigatureOperator(next.text.0), next.text.1 == 0,
                          !(drawCursor && frame.cursorRow == next.row && frame.cursorColumn == next.column) else { break }
                    text.append(UInt8(bitPattern: next.text.0)); span += 1
                }
                if span > 1 { operatorText = String(bytes:text,encoding:.utf8); index += span - 1 }
            }
            let rect = CGRect(x: inset + CGFloat(cellData.column) * cell.width * fit, y: inset + CGFloat(cellData.row) * cell.height * fit, width: cell.width * fit * CGFloat(span), height: cell.height * fit)
            var bg = cellData.background, fg = cellData.foreground
            func resolved(_ color: TerminalThemeColor) -> UInt32 {
                color.resolve(foreground: cellData.foreground, background: cellData.background, windowForeground: frame.foreground, windowBackground: frame.background)
            }
            if cellData.flags & 8 != 0 {
                bg = theme.selectionBackground.map(resolved) ?? theme.accent
                fg = theme.selectionForeground.map(resolved) ?? (theme.isLight ? 0xffffff : 0x15191f)
            }
            else if cellData.flags & 128 != 0 { bg = 0xe3ba64; fg = 0x2b2314 }
            else if cellData.flags & 64 != 0 { bg = 0x81714d; fg = 0xffffff }
            let cursorCell = drawCursor && focused && frame.cursorStyle == 1 && cellData.column >= frame.cursorColumn && Int(cellData.column) < Int(frame.cursorColumn) + cursorWidth && cellData.row == frame.cursorRow
            if cursorCell {
                bg = theme.cursorColor.map(resolved) ?? frame.cursorColor
                fg = theme.cursorText.map(resolved) ?? frame.background
            }
            let opaqueCell = cellData.flags & (8 | 64 | 128) != 0 || cellData.attributes & 16 != 0 || cursorCell
            let explicitBackground = cellData.attributes & 8 != 0
            if bg != frame.background || opacity < 1 && (opaqueCell || explicitBackground) {
                let alpha = !opaqueCell && theme.backgroundOpacityCells == true ? Float(opacity) : 1
                backgrounds.append(quad(rect,bg,alpha:alpha))
            }
            if cellData.width == 0 { continue }
            if cellData.attributes & 4 != 0 && cellData.attributes & 2 == 0 &&
                (cellData.text.0 != 0 && (cellData.text.0 != 32 || cellData.text.1 != 0) || cellData.flags & 52 != 0) {
                hasBlinkingText = true
            }
            if !textBlink.drawsText(attributes: cellData.attributes) { continue }
            // Pixel-art terminals use block characters as colored geometry. Font metrics,
            // contrast remapping, and per-color atlas entries all corrupt those images.
            if cellData.text.0 == -30 && cellData.text.1 == -106 && cellData.text.3 == 0 {
                let last = UInt8(bitPattern: cellData.text.2)
                if (0x80...0x9f).contains(last) {
                    let code = UInt32(last) + 0x2500
                    if (0x2591...0x2593).contains(code) {
                        var shade = quad(rect, fg); shade.textured = code - 0x258f
                        foregrounds.append(shade)
                    } else {
                        for part in TerminalCellGeometry.blocks[Int(code - 0x2580)] {
                            foregrounds.append(quad(CGRect(x:rect.minX + part.minX * rect.width, y:rect.minY + part.minY * rect.height, width:part.width * rect.width, height:part.height * rect.height), fg))
                        }
                    }
                    if cellData.flags & 52 != 0 { decorations(cellData, rect: rect, foreground: fg, span: span) }
                    continue
                }
            }
            let text = operatorText ?? withUnsafePointer(to: &cellData.text) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString:$0) } }
            let firstScalar = text.unicodeScalars.first?.value ?? 0
            if contrastCorrection && (!text.isEmpty && text != " " || cellData.flags & 52 != 0) && !TerminalCellDrawing.isGraphicsElement(firstScalar) { fg = corrected(fg, against:bg) }
            if !text.isEmpty && text != " " {
                var key = GlyphAtlas.Key(text:text,bold:cellData.flags & 1 != 0,italic:cellData.flags & 2 != 0,width:max(span,Int(cellData.width)))
                key.clusters = textClusters
                if cellData.width == 1 && TerminalFontRasterizer.isPrivateUse(firstScalar) && !TerminalCellDrawing.isGraphicsElement(firstScalar),
                   index + 1 < frame.count && cellData.column + 1 < frame.columns {
                    let next = cells[index + 1]
                    var previousIsSymbol = false
                    if cellData.column > 0 {
                        var previous = cells[index - 1]
                        let scalar = withUnsafePointer(to:&previous.text) { $0.withMemoryRebound(to:CChar.self,capacity:128) { String(cString:$0).unicodeScalars.first?.value ?? 0 } }
                        previousIsSymbol = TerminalFontRasterizer.isPrivateUse(scalar) && !TerminalCellDrawing.isGraphicsElement(scalar)
                    }
                    if !previousIsSymbol && (next.text.0 == 0 || (next.text.0 == 32 && next.text.1 == 0)) { key.constraintWidth = 2 }
                }
                if let entry = atlas.glyph(key) {
                    let glyph = entry.rect
                    foregrounds.append(TerminalQuad(rect:SIMD4(Float(rect.minX-CGFloat(entry.padding)/scale*fit),Float(rect.minY),Float(glyph.width/scale*fit),Float(glyph.height/scale*fit)),uv:SIMD4(Float(glyph.minX/2048),Float(glyph.minY/2048),Float(glyph.width/2048),Float(glyph.height/2048)),color:entry.colored ? SIMD4(repeating:1) : Self.rgba(fg),textured:1))
                }
            }
            if cellData.flags & 52 != 0 { decorations(cellData, rect: rect, foreground: fg, span: span) }
        }
        updateTextBlink(hasBlinkingText: hasBlinkingText, canPresent: true)
        if drawCursor {
            let cursorForeground = cursorIndex < frame.count ? cells[cursorIndex].foreground : frame.foreground
            let cursorBackground = cursorIndex < frame.count ? cells[cursorIndex].background : frame.background
            let cursorColor = theme.cursorColor?.resolve(foreground: cursorForeground, background: cursorBackground,
                windowForeground: frame.foreground, windowBackground: frame.background) ?? frame.cursorColor
            var rect = CGRect(x:inset+CGFloat(frame.cursorColumn)*cell.width*fit,y:inset+CGFloat(frame.cursorRow)*cell.height*fit,width:cell.width*fit*CGFloat(cursorWidth),height:cell.height*fit)
            if focused && frame.cursorStyle != 3 {
                if frame.cursorStyle == 0 { rect.size.width = max(1/scale,1.5*fit);foregrounds.append(quad(rect,cursorColor)) }
                else if frame.cursorStyle == 2 { rect.origin.y = rect.maxY-2*fit;rect.size.height = 2*fit;foregrounds.append(quad(rect,cursorColor)) }
            } else if interactive {
                for edge in [CGRect(x:rect.minX,y:rect.minY,width:rect.width,height:fit), CGRect(x:rect.minX,y:rect.maxY-fit,width:rect.width,height:fit), CGRect(x:rect.minX,y:rect.minY,width:fit,height:rect.height), CGRect(x:rect.maxX-fit,y:rect.minY,width:fit,height:rect.height)] { foregrounds.append(quad(edge,cursorColor,alpha:0.5)) }
            }
        }
        let quadCount = backgrounds.count + foregrounds.count
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red:Double((frame.background>>16)&255)/255*opacity,green:Double((frame.background>>8)&255)/255*opacity,blue:Double(frame.background&255)/255*opacity,alpha:opacity)
        let hasBelowBackground = imageDraws.contains { $0.z < Int32.min / 2 }
        let replaceBackground = opacity < 1 && theme.backgroundOpacityCells == true && !backgrounds.isEmpty && !hasBelowBackground
        let backgroundPipeline = replaceBackground ? Self.makePipeline(device: device, blending: false) : nil
        // A failed shader cannot leave a half-configured pass or acknowledge a
        // frame that was not drawn. A later invalidation can retry construction.
        guard !replaceBackground || backgroundPipeline != nil, let command = queue.makeCommandBuffer() else { return }
        let required = max(64, quadCount * MemoryLayout<TerminalQuad>.stride)
        if buffers[slot] == nil || buffers[slot]!.length < required { buffers[slot] = device.makeBuffer(length:required*2,options:.storageModeShared) }
        guard let buffer = buffers[slot], let encoder = command.makeRenderCommandEncoder(descriptor:pass) else { return }
        backgrounds.withUnsafeBytes { if let base = $0.baseAddress { memcpy(buffer.contents(), base, $0.count) } }
        foregrounds.withUnsafeBytes { if let base = $0.baseAddress { memcpy(buffer.contents().advanced(by: backgrounds.count * MemoryLayout<TerminalQuad>.stride), base, $0.count) } }
        encoder.setRenderPipelineState(pipeline);encoder.setVertexBuffer(buffer,offset:0,index:0)
        var viewport = SIMD2(Float(view.bounds.width),Float(view.bounds.height));encoder.setVertexBytes(&viewport,length:MemoryLayout<SIMD2<Float>>.stride,index:1)
        encoder.setFragmentTexture(atlas.texture,index:0)
        func drawImages(where predicate: (Int32) -> Bool) {
            for draw in imageDraws where predicate(draw.z) {
                var quad = draw.quad
                encoder.setVertexBytes(&quad, length: MemoryLayout<TerminalQuad>.stride, index: 0)
                encoder.setFragmentTexture(draw.texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentTexture(atlas.texture, index: 0)
        }
        if imageDraws.isEmpty && !(opacity < 1 && theme.backgroundOpacityCells == true && !backgrounds.isEmpty) {
            if quadCount > 0 { encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:quadCount) }
        } else {
        if !imageDraws.isEmpty { drawImages { $0 < Int32.min / 2 } }
        if let backgroundPipeline {
            // Replace the clear color for translucent explicit backgrounds.
            // Blending them over it would apply opacity twice (0.5 -> 0.75).
            encoder.setRenderPipelineState(backgroundPipeline)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:backgrounds.count)
            encoder.setRenderPipelineState(pipeline)
        } else if !backgrounds.isEmpty { encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:backgrounds.count) }
        if !imageDraws.isEmpty { drawImages { $0 >= Int32.min / 2 && $0 < 0 } }
        if !foregrounds.isEmpty { encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:foregrounds.count,baseInstance:backgrounds.count) }
        if !imageDraws.isEmpty { drawImages { $0 >= 0 } }
        }
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
        committed = true
        presentation.submitted(revision: revision)
        command.commit()
        // An atlas containing old scrollback glyphs may need one fresh pass.
        // If the visible glyph set itself cannot fit, endlessly retrying the
        // same frame consumes a CPU/GPU core without adding any content.
        if atlas.full && !replacingFullAtlas { requestDraw() }
    }

    private static func rgba(_ value: UInt32, alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(Float((value>>16)&255)/255*alpha,Float((value>>8)&255)/255*alpha,Float(value&255)/255*alpha,alpha)
    }

    private static func imageQuad(placement: WireGraphicsPlacement, image: WireGraphicsImage, scene: TerminalGraphicsState,
                                  frame: ILFrame, cell: CGSize, fit: CGFloat, inset: CGFloat, bounds: CGRect) -> TerminalQuad? {
        guard placement.pixelWidth > 0, placement.pixelHeight > 0, placement.sourceWidth > 0, placement.sourceHeight > 0 else { return nil }
        let xScale = cell.width * fit / CGFloat(scene.cellWidth), yScale = cell.height * fit / CGFloat(scene.cellHeight)
        let row = Double(frame.scrollTotal) - Double(frame.rows) + Double(placement.row) - Double(frame.scrollOffset)
        let destination = CGRect(x: inset + CGFloat(placement.column) * cell.width * fit + CGFloat(placement.xOffset) * xScale,
            y: inset + CGFloat(row) * cell.height * fit + CGFloat(placement.yOffset) * yScale,
            width: CGFloat(placement.pixelWidth) * xScale, height: CGFloat(placement.pixelHeight) * yScale)
        let viewport = CGRect(x: inset, y: inset, width: CGFloat(frame.columns) * cell.width * fit, height: CGFloat(frame.rows) * cell.height * fit).intersection(bounds)
        let clipped = destination.intersection(viewport)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let sourceWidth = CGFloat(placement.sourceWidth) / CGFloat(image.width), sourceHeight = CGFloat(placement.sourceHeight) / CGFloat(image.height)
        return TerminalQuad(rect: SIMD4(Float(clipped.minX), Float(clipped.minY), Float(clipped.width), Float(clipped.height)),
            uv: SIMD4(Float(CGFloat(placement.sourceX) / CGFloat(image.width) + (clipped.minX - destination.minX) / destination.width * sourceWidth),
                Float(CGFloat(placement.sourceY) / CGFloat(image.height) + (clipped.minY - destination.minY) / destination.height * sourceHeight),
                Float(clipped.width / destination.width * sourceWidth), Float(clipped.height / destination.height * sourceHeight)),
            color: SIMD4(repeating: 1), textured: 8)
    }

    private static func isLigatureOperator(_ character: CChar) -> Bool {
        switch character {
        case 33,37,38,42,43,45,46,47,58,60,61,62,63,94,124,126: return true
        default: return false
        }
    }

    private func corrected(_ foreground: UInt32, against background: UInt32) -> UInt32 {
        let key = UInt64(foreground)<<32 | UInt64(background)
        if let cached=contrastCache[key] { return cached }
        let result = ContrastCorrection.correct(foreground, background:background, target:engine.theme.foreground, minimumContrast:engine.theme.minimumContrast ?? 4.5)
        if contrastCache.count>8192 { contrastCache.removeAll(keepingCapacity:true) }
        contrastCache[key]=result;return result
    }
}
