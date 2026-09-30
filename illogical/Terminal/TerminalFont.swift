import AppKit
import CoreText

/// Grid metrics in device pixels, computed like Ghostty's `src/font/Metrics.zig`
/// so that cells, baselines and decorations land on the same pixels.
struct TerminalCellMetrics: Hashable {
    var cellWidth: Int
    var cellHeight: Int
    /// Distance from the bottom of the cell up to the text baseline.
    var baseline: Int
    /// Distances from the top of the cell down to the top of each stroke.
    var underlinePosition: Int
    var underlineThickness: Int
    var strikethroughPosition: Int
    var strikethroughThickness: Int
    var overlinePosition: Int
    var overlineThickness: Int
    var boxThickness: Int
    var cursorThickness: Int
    /// Cursors keep the font's natural height when `adjust-cell-height`
    /// changes the cell, centered like Ghostty's cursor sprites.
    var cursorHeight: Int
    var cursorTop: Int { (cellHeight - cursorHeight) / 2 }

    /// `font` must already be sized in device pixels.
    init(font: CTFont, options: TerminalFontOptions) {
        let ascent = CTFontGetAscent(font), descent = -CTFontGetDescent(font), lineGap = CTFontGetLeading(font)
        let faceWidth = Self.maximumASCIIAdvance(font)
        let faceHeight = ascent - descent + lineGap
        let height = max(1, faceHeight.rounded())
        let faceBaseline = lineGap / 2 - descent
        // Center the face in the rounded height before rounding the baseline.
        let baseline = (faceBaseline - (height - faceHeight) / 2).rounded()
        var faceY = baseline - faceBaseline
        let topToBaseline = height - baseline

        let xHeight = CTFontGetXHeight(font) > 0 ? CTFontGetXHeight(font) : 0.75 * 0.75 * ascent
        let underlineThickness = CTFontGetUnderlineThickness(font) > 0 ? CTFontGetUnderlineThickness(font) : 0.15 * xHeight
        let underlinePosition = CTFontGetUnderlinePosition(font) != 0 ? CTFontGetUnderlinePosition(font) : -underlineThickness
        let strikeout = Self.strikeout(font)
        let strikeThickness = strikeout?.thickness ?? underlineThickness
        let strikePosition = strikeout?.position ?? (xHeight + strikeThickness) / 2

        cellWidth = max(1, Int(faceWidth.rounded()))
        cellHeight = Int(height)
        self.baseline = Int(baseline)
        self.underlineThickness = max(1, Int(underlineThickness.rounded(.up)))
        self.underlinePosition = Int((topToBaseline - underlinePosition).rounded())
        strikethroughThickness = max(1, Int(strikeThickness.rounded(.up)))
        strikethroughPosition = Int((topToBaseline - strikePosition).rounded())
        overlinePosition = 0
        overlineThickness = self.underlineThickness
        boxThickness = self.underlineThickness
        cursorHeight = cellHeight
        cursorThickness = max(1, options.cursorThickness.applied(to: 1))

        let adjusted = max(1, options.cellHeight.applied(to: cellHeight))
        if adjusted != cellHeight {
            // Split the added pixels so the face stays centered; an odd pixel
            // goes to the side the rounded face is further from.
            let half = Double(adjusted - cellHeight) / 2
            let aboveCenter = faceY - (Double(cellHeight) - faceHeight) / 2 > 0
            let top = Int(aboveCenter ? half.rounded(.up) : half.rounded(.down))
            let bottom = Int(aboveCenter ? half.rounded(.down) : half.rounded(.up))
            self.baseline += bottom
            faceY += Double(bottom)
            self.underlinePosition += top
            strikethroughPosition += top
            overlinePosition += top
            cellHeight = adjusted
        }
    }

    func pointSize(scale: CGFloat) -> NSSize {
        NSSize(width: CGFloat(cellWidth) / scale, height: CGFloat(cellHeight) / scale)
    }

    private static func maximumASCIIAdvance(_ font: CTFont) -> CGFloat {
        var characters = (32..<127).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        return advances.map(\.width).max() ?? CTFontGetSize(font) / 2
    }

    /// The OS/2 table's strikeout stroke, when the font specifies one.
    private static func strikeout(_ font: CTFont) -> (position: CGFloat, thickness: CGFloat)? {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, table.count >= 30 else { return nil }
        func int16(_ offset: Int) -> CGFloat { CGFloat(Int16(bitPattern: UInt16(table[offset]) << 8 | UInt16(table[offset + 1]))) }
        let size = int16(26), position = int16(28)
        guard size > 0 else { return nil }
        let pixelsPerUnit = CTFontGetSize(font) / CGFloat(CTFontGetUnitsPerEm(font))
        return (position * pixelsPerUnit, size * pixelsPerUnit)
    }
}

/// JetBrains Mono Nerd Font ships in the app bundle in all four styles. It is
/// registered for this process only, never installed into the user's fonts.
enum TerminalBundledFonts {
    static let family = "JetBrainsMono Nerd Font"

    /// Registers the faces on first use. Returns whether any face is available.
    @discardableResult
    static func register() -> Bool { registered }

    private static let registered: Bool = {
        var available = false
        for style in ["Regular", "Bold", "Italic", "BoldItalic"] {
            guard let url = Bundle.main.url(forResource: "JetBrainsMonoNerdFont-\(style)", withExtension: "ttf") else { continue }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                available = true
            } else if let error = error?.takeRetainedValue(), CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue {
                available = true
            }
        }
        return available
    }()
}

/// Rasterizes cell text into trimmed coverage bitmaps positioned relative to
/// the cell origin. Font discovery is lazy: ASCII startup never enumerates fonts.
@MainActor
final class TerminalFontRasterizer {
    struct Style: OptionSet, Hashable {
        let rawValue: UInt8
        static let bold = Style(rawValue: 1)
        static let italic = Style(rawValue: 2)
    }

    struct Key: Hashable {
        var text: String
        var style: Style
        /// Cells the text occupies.
        var columns: Int
        /// Cells an icon may grow into when followed by blank space.
        var constraintColumns = 0
        /// Grid positions of contextual or ligature runs; empty for single cells.
        var clusters: [TerminalTextRuns.Cluster] = []

        init(text: String, bold: Bool = false, italic: Bool = false, width: Int = 1) {
            self.text = text
            style = Style().union(bold ? .bold : []).union(italic ? .italic : [])
            columns = width
        }
    }

    struct Bitmap {
        /// One coverage byte per pixel, or premultiplied RGBA when `colored`.
        var pixels: [UInt8]
        var width: Int
        var height: Int
        /// Offset of the bitmap's top-left corner from the cell's top-left corner.
        var left: Int
        var top: Int
        var colored: Bool
        var isEmpty: Bool { width == 0 || height == 0 }
        var bytesPerPixel: Int { colored ? 4 : 1 }
    }

    /// A face with the synthetic styling Ghostty applies when a family lacks it.
    private struct Face {
        let font: CTFont
        let syntheticBold: Bool
    }

    let font: NSFont
    let scale: CGFloat
    let metrics: TerminalCellMetrics
    let options: TerminalFontOptions
    private let regular: CTFont
    private var faces: [Style: Face] = [:]
    private var fallbacks: [Key: CTFont] = [:]
    /// Approximately tan(15deg), matching Ghostty's synthetic italic.
    private static var italicSkew = CGAffineTransform(a: 1, b: 0, c: 0.267949, d: 1, tx: 0, ty: 0)
    private lazy var nerdFont: CTFont? = {
        // CoreText's default cascade does not reliably choose installed PUA
        // fonts. The bundled family always has the Nerd Font symbols.
        TerminalBundledFonts.register()
        for name in ["Symbols Nerd Font Mono", "Symbols Nerd Font", TerminalBundledFonts.family] {
            if let installed = NSFont(name: name, size: font.pointSize) {
                return CTFontCreateWithName(installed.fontName as CFString, font.pointSize * scale, nil)
            }
        }
        return nil
    }()

    init(font: NSFont, scale: CGFloat, options: TerminalFontOptions = .defaults) {
        self.font = font; self.scale = scale; self.options = options
        let base = CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize * scale, nil, nil)
        regular = Self.configuredFont(base, options: options)
        metrics = TerminalCellMetrics(font: regular, options: options)
        faces[[]] = Face(font: regular, syntheticBold: false)
    }

    /// Applies OpenType features and, unless `variations` is false, variation axes.
    static func configuredFont(_ base: CTFont, options: TerminalFontOptions, variations: Bool = true) -> CTFont {
        let features = options.features.map {
            [kCTFontOpenTypeFeatureTag as String: $0.key, kCTFontOpenTypeFeatureValue as String: $0.value] as NSDictionary
        }
        var attributes: [String: Any] = [kCTFontFeatureSettingsAttribute as String: features]
        if variations {
            var axes: [NSNumber: Double] = [:]
            for (tag, value) in options.variations where tag.utf8.count == 4 {
                axes[NSNumber(value: tag.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })] = value
            }
            attributes[kCTFontVariationAttribute as String] = axes
        }
        return CTFontCreateCopyWithAttributes(base, 0, nil, CTFontDescriptorCreateWithAttributes(attributes as CFDictionary))
    }

    private func face(_ style: Style) -> Face {
        if let cached = faces[style] { return cached }
        func styled(_ font: CTFont, _ trait: CTFontSymbolicTraits) -> CTFont? {
            guard let copy = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, trait, trait),
                  CTFontGetSymbolicTraits(copy).contains(trait) else { return nil }
            // Features follow the family; `font-variation` applies to regular only.
            return Self.configuredFont(copy, options: options, variations: false)
        }
        var font = regular
        if style.contains(.italic) {
            font = styled(regular, .traitItalic) ?? CTFontCreateCopyWithAttributes(regular, 0, &Self.italicSkew, nil)
        }
        var syntheticBold = false
        if style.contains(.bold) {
            if let bold = styled(font, .traitBold) { font = bold } else { syntheticBold = true }
        }
        let face = Face(font: font, syntheticBold: syntheticBold)
        faces[style] = face
        return face
    }

    /// The font that draws `text`, falling back to a Nerd Font for icons.
    func resolvedFont(for text: String, bold: Bool = false, italic: Bool = false) -> CTFont {
        resolvedFace(for: text, style: Style().union(bold ? .bold : []).union(italic ? .italic : [])).font
    }

    private func resolvedFace(for text: String, style: Style) -> Face {
        let face = face(style)
        guard text.unicodeScalars.contains(where: { Self.isPrivateUse($0.value) }) else { return face }
        var key = Key(text: text); key.style = style
        if let cached = fallbacks[key] { return Face(font: cached, syntheticBold: face.syntheticBold) }
        let coverage = CTFontCopyCharacterSet(face.font)
        let missing = text.unicodeScalars.contains { Self.isPrivateUse($0.value) && !CFCharacterSetIsLongCharacterMember(coverage, $0.value) }
        let font = missing ? nerdFont ?? face.font : face.font
        fallbacks[key] = font
        return Face(font: font, syntheticBold: face.syntheticBold)
    }

    func rasterize(_ key: Key) -> Bitmap? {
        let columns = max(1, key.columns, key.constraintColumns)
        let cellWidth = metrics.cellWidth, cellHeight = metrics.cellHeight
        // Glyphs may overhang their cells; the canvas is trimmed afterwards.
        let padX = cellWidth, padY = cellHeight / 2
        let canvas = Canvas(width: cellWidth * columns + padX * 2, height: cellHeight + padY * 2, padX: padX, padY: padY)

        if key.text.unicodeScalars.count == 1, let scalar = key.text.unicodeScalars.first, TerminalCellDrawing.supports(scalar.value) {
            return canvas.render(colored: false, colorspace: options.colorspace) { context in
                // Cell drawing uses a top-left origin with y pointing down.
                context.translateBy(x: CGFloat(padX), y: CGFloat(canvas.height - padY))
                context.scaleBy(x: 1, y: -1)
                TerminalCellDrawing.draw(scalar.value, in: context, size: CGSize(width: cellWidth * max(1, key.columns), height: cellHeight),
                                         thickness: CGFloat(metrics.boxThickness))
            }
        }

        let face = resolvedFace(for: key.text, style: key.style)
        var clusters = key.clusters
        if clusters.isEmpty && key.columns > 1 && key.text.utf8.count == key.columns && key.text.utf8.allSatisfy({ $0 < 0x80 }) {
            // Keep operator ligatures on the same pixel grid as individual cells.
            clusters = (0..<key.columns).map { .init(utf16Offset: $0, utf16Count: 1, column: $0, width: 1) }
        }
        let shaped = clusters.isEmpty ? nil : TerminalTextRuns.shape(text: key.text, clusters: clusters, font: face.font, cellWidth: CGFloat(cellWidth))
        let line = shaped == nil ? CTLineCreateWithAttributedString(NSAttributedString(string: key.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): face.font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])) : nil
        let fonts = shaped?.map(\.font) ?? line.map { (CTLineGetGlyphRuns($0) as? [CTRun] ?? []).map(TerminalTextRuns.font) } ?? []
        let colored = fonts.contains { CTFontGetSymbolicTraits($0).contains(.traitColorGlyphs) }
        let baseline = CGFloat(padY + metrics.baseline)

        return canvas.render(colored: colored, colorspace: options.colorspace) { context in
            // In an alpha-only context, gray controls CoreText smoothing strength
            // rather than tinting the result. This matches Ghostty's rasterizer.
            let gray = colored ? 1 : CGFloat(min(255, max(0, options.thickenStrength))) / 255
            context.setFillColor(gray: gray, alpha: 1)
            context.setStrokeColor(gray: gray, alpha: 1)
            context.setShouldSmoothFonts(options.thicken && !colored)
            if face.syntheticBold && !colored {
                context.setTextDrawingMode(.fillStroke)
                context.setLineWidth(max(font.pointSize / 14, 1))
            }
            if let shaped {
                // Tiles of a long contextual run draw only their own columns.
                let leadingContext = (key.clusters.first?.column ?? 0) < 0
                let trailingContext = key.clusters.last.map { $0.column + $0.width > key.columns } ?? false
                let left = leadingContext ? padX : 0
                let right = trailingContext ? padX + cellWidth * key.columns : canvas.width
                context.clip(to: CGRect(x: left, y: 0, width: right - left, height: canvas.height))
                TerminalTextRuns.draw(shaped, in: context, origin: CGPoint(x: CGFloat(padX), y: baseline))
                return
            }
            guard let line else { return }
            let icon = key.text.unicodeScalars.contains { Self.isPrivateUse($0.value) }
            if icon || colored {
                // Icons and emoji fit the cells libghostty assigned them.
                let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
                let available = CGFloat(cellWidth * columns), height = CGFloat(cellHeight)
                let factor = min(1, available / max(1, bounds.width), height / max(1, bounds.height))
                let width = bounds.width * factor
                let x = icon ? max(0, (CGFloat(cellWidth) - width) / 2) : (available - width) / 2
                let y = colored ? (height - bounds.height * factor) / 2 - bounds.minY * factor
                    : min(height - bounds.maxY * factor, max(-bounds.minY * factor, CGFloat(metrics.baseline)))
                context.translateBy(x: CGFloat(padX) + x - bounds.minX * factor, y: CGFloat(padY) + y)
                context.scaleBy(x: factor, y: factor)
                context.textPosition = .zero
            } else {
                context.textPosition = CGPoint(x: CGFloat(padX), y: baseline)
            }
            CTLineDraw(line, context)
        }
    }

    static func isPrivateUse(_ scalar: UInt32) -> Bool {
        (0xe000...0xf8ff).contains(scalar) || (0xf0000...0xffffd).contains(scalar) || (0x100000...0x10fffd).contains(scalar)
    }
}

/// A scratch bitmap around a cell, trimmed to its drawn pixels.
private struct Canvas {
    let width: Int
    let height: Int
    let padX: Int
    let padY: Int

    func render(colored: Bool, colorspace: TerminalColorspace, draw: (CGContext) -> Void) -> TerminalFontRasterizer.Bitmap? {
        guard width > 0, height > 0 else { return nil }
        let bytesPerPixel = colored ? 4 : 1
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            let space = colored ? CGColorSpace(name: colorspace == .displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
                                : CGColorSpace(name: CGColorSpace.linearGray)!
            let info = colored ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                               : CGImageAlphaInfo.alphaOnly.rawValue
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * bytesPerPixel, space: space, bitmapInfo: info) else { return false }
            context.setShouldAntialias(true)
            context.setAllowsFontSmoothing(true)
            context.setShouldSmoothFonts(false)
            // Glyph origins are pixel-aligned by the caller; never quantize them.
            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            context.setAllowsFontSubpixelQuantization(false)
            context.setShouldSubpixelQuantizeFonts(false)
            draw(context)
            return true
        }
        guard drawn else { return nil }
        return trimmed(pixels, bytesPerPixel: bytesPerPixel)
    }

    /// Crops to the rows and columns with coverage. CoreGraphics rows run
    /// top to bottom in memory, so row 0 is the top of the canvas.
    private func trimmed(_ pixels: [UInt8], bytesPerPixel: Int) -> TerminalFontRasterizer.Bitmap {
        var minX = width, minY = height, maxX = -1, maxY = -1
        pixels.withUnsafeBufferPointer { buffer in
            for y in 0..<height {
                let row = y * width * bytesPerPixel
                for x in 0..<width where buffer[row + x * bytesPerPixel + bytesPerPixel - 1] != 0 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else {
            return .init(pixels: [], width: 0, height: 0, left: 0, top: 0, colored: bytesPerPixel == 4)
        }
        let trimmedWidth = maxX - minX + 1, trimmedHeight = maxY - minY + 1
        var result = [UInt8](repeating: 0, count: trimmedWidth * trimmedHeight * bytesPerPixel)
        for y in 0..<trimmedHeight {
            let source = ((minY + y) * width + minX) * bytesPerPixel
            result.replaceSubrange(y * trimmedWidth * bytesPerPixel..<(y + 1) * trimmedWidth * bytesPerPixel,
                                   with: pixels[source..<source + trimmedWidth * bytesPerPixel])
        }
        return .init(pixels: result, width: trimmedWidth, height: trimmedHeight, left: minX - padX, top: minY - padY,
                     colored: bytesPerPixel == 4)
    }
}
