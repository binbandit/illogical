import AppKit
import CoreText

/// Font discovery is lazy: ordinary ASCII startup never enumerates installed fonts.
@MainActor
final class TerminalFontRasterizer {
    struct Key: Hashable {
        let text: String
        let bold: Bool
        let italic: Bool
        let width: Int
        var constraintWidth = 0
        var clusters: [TerminalTextRuns.Cluster] = []
    }
    struct Bitmap {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let padding: Int
        let colored: Bool
    }

    let font: NSFont
    let scale: CGFloat
    let cell: NSSize
    let options: TerminalFontOptions
    private let regular: CTFont
    private var variants: [Int: CTFont] = [:]
    private var resolved: [String: CTFont] = [:]
    private static let bundledFallback: CGFont? = {
        guard let url = Bundle.main.url(forResource: "JetBrainsMonoNerdFont-Regular", withExtension: "ttf"),
              let provider = CGDataProvider(url: url as CFURL) else { return nil }
        return CGFont(provider)
    }()
    private lazy var nerdFont: CTFont? = {
        // CoreText's default cascade does not reliably choose installed PUA fonts.
        for name in ["Symbols Nerd Font Mono", "Symbols Nerd Font", "JetBrainsMono Nerd Font"] {
            if let installed = NSFont(name: name, size: font.pointSize) {
                return CTFontCreateWithName(installed.fontName as CFString, font.pointSize * scale, nil)
            }
        }
        return Self.bundledFallback.map { CTFontCreateWithGraphicsFont($0, font.pointSize * scale, nil, nil) }
    }()

    init(font: NSFont, scale: CGFloat, cell: NSSize, options: TerminalFontOptions = .defaults) {
        self.font = font; self.scale = scale; self.cell = cell; self.options = options
        let base = CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize * scale, nil, nil)
        regular = Self.configuredFont(base, options: options)
        variants[0] = regular
    }

    static func configuredFont(_ base: CTFont, options: TerminalFontOptions) -> CTFont {
        let features = options.features.map { [kCTFontOpenTypeFeatureTag as String: $0.key, kCTFontOpenTypeFeatureValue as String: $0.value] as NSDictionary }
        var axes: [NSNumber: Double] = [:]
        for (tag, value) in options.variations where tag.utf8.count == 4 {
            axes[NSNumber(value: tag.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })] = value
        }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute as String: features, kCTFontVariationAttribute as String: axes] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, 0, nil, descriptor)
    }

    func resolvedFont(for text: String, bold: Bool = false, italic: Bool = false) -> CTFont {
        let style = (bold ? 1 : 0) | (italic ? 2 : 0)
        let base: CTFont
        if let cached = variants[style] { base = cached }
        else {
            var traits: CTFontSymbolicTraits = []
            if bold { traits.insert(.traitBold) }
            if italic { traits.insert(.traitItalic) }
            base = CTFontCreateCopyWithSymbolicTraits(regular, 0, nil, traits, traits) ?? regular
            variants[style] = base
        }
        guard text.unicodeScalars.contains(where: { Self.isPrivateUse($0.value) }) else { return base }
        let cacheKey = "\(style):\(text)"
        if let cached = resolved[cacheKey] { return cached }
        let coverage = CTFontCopyCharacterSet(base)
        let missing = text.unicodeScalars.contains { Self.isPrivateUse($0.value) && !CFCharacterSetIsLongCharacterMember(coverage, $0.value) }
        let result = missing ? nerdFont ?? base : base
        resolved[cacheKey] = result
        return result
    }

    func rasterize(_ key: Key) -> Bitmap? {
        let padding = 2 * Int(ceil(scale))
        let cellWidth = Int(round(cell.width * scale * CGFloat(max(1, key.width, key.constraintWidth))))
        let width = cellWidth + padding * 2
        let height = Int(round(cell.height * scale))
        guard width > 0, height > 0 else { return nil }
        if key.text.unicodeScalars.count == 1, let scalar = key.text.unicodeScalars.first,
           TerminalCellDrawing.supports(scalar.value) {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return }
                context.translateBy(x: CGFloat(padding), y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
                TerminalCellDrawing.draw(scalar.value, in: context, size: CGSize(width: cellWidth, height: height))
            }
            return Bitmap(bytes: bytes, width: width, height: height, padding: padding, colored: false)
        }
        let font = resolvedFont(for: key.text, bold: key.bold, italic: key.italic)
        let shaped = key.clusters.isEmpty ? nil : TerminalTextRuns.shape(text: key.text, clusters: key.clusters, font: font, cellWidth: cell.width * scale)
        let attributed = NSAttributedString(string: key.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
        let line = shaped == nil ? CTLineCreateWithAttributedString(attributed) : nil
        let runs = line.map { CTLineGetGlyphRuns($0) as! [CTRun] } ?? []
        let colored = shaped?.contains { CTFontGetSymbolicTraits($0.font).contains(.traitColorGlyphs) } ?? runs.contains { run in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            return CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)
        }
        let components = colored ? 4 : 1
        var pixels = [UInt8](repeating: 0, count: width * height * components)
        pixels.withUnsafeMutableBytes { buffer in
            let space = colored ? CGColorSpaceCreateDeviceRGB() : CGColorSpace(name: CGColorSpace.linearGray)!
            let info = colored ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue : CGImageAlphaInfo.alphaOnly.rawValue
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * components,
                                          space: space, bitmapInfo: info) else { return }
            // In an alpha-only context, gray controls CoreText smoothing strength,
            // rather than tinting the result. This matches Ghostty's macOS rasterizer.
            context.setFillColor(gray: colored ? 1 : CGFloat(max(0,min(255,options.thickenStrength))) / 255, alpha: 1)
            context.setStrokeColor(gray: colored ? 1 : CGFloat(max(0,min(255,options.thickenStrength))) / 255, alpha: 1)
            context.setShouldAntialias(true)
            context.setAllowsFontSmoothing(true)
            context.setShouldSmoothFonts(options.thicken && !colored)
            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            context.setAllowsFontSubpixelQuantization(false)
            context.setShouldSubpixelQuantizeFonts(false)
            // A shared baseline keeps fallback, combining marks, and ASCII aligned.
            let baseline = round((CGFloat(height) - CTFontGetAscent(regular) - CTFontGetDescent(regular)) / 2 + CTFontGetDescent(regular))
            if let shaped {
                let hasLeadingContext = (key.clusters.first?.column ?? 0) < 0
                let hasTrailingContext = key.clusters.last.map { $0.column + $0.width > key.width } ?? false
                let left = hasLeadingContext ? padding : 0
                let right = hasTrailingContext ? padding + cellWidth : width
                context.clip(to: CGRect(x: left, y: 0, width: right - left, height: height))
                TerminalTextRuns.draw(shaped, in: context, origin: CGPoint(x: CGFloat(padding), y: baseline))
                return
            }
            guard let line else { return }
            let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            let icon = key.text.unicodeScalars.contains { Self.isPrivateUse($0.value) }
            if icon || colored {
                // Terminal PUA icons and emoji occupy exactly the width assigned by libghostty.
                let factor = min(1, CGFloat(cellWidth) / max(1, bounds.width), CGFloat(height) / max(1, bounds.height))
                let horizontalCenter = icon ? max(0,(cell.width * scale - bounds.width * factor) / 2) : (CGFloat(cellWidth) - bounds.width * factor) / 2
                let originX = CGFloat(padding) + horizontalCenter - bounds.minX * factor
                let originY = colored ? (CGFloat(height) - bounds.height * factor) / 2 - bounds.minY * factor
                    : min(CGFloat(height) - bounds.maxY * factor, max(-bounds.minY * factor, baseline))
                context.translateBy(x: originX, y: originY)
                context.scaleBy(x: factor, y: factor)
                context.textPosition = .zero
            } else if key.width > 1 && key.text.utf8.count == key.width {
                let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
                context.translateBy(x: CGFloat(padding), y: baseline)
                context.scaleBy(x: advance > 0 ? CGFloat(cellWidth) / advance : 1, y: 1)
                context.textPosition = .zero
            } else { context.textPosition = CGPoint(x: CGFloat(padding), y: baseline) }
            CTLineDraw(line, context)
        }
        var bytes: [UInt8]
        if colored { bytes = pixels }
        else {
            bytes = [UInt8](repeating: 0, count: pixels.count * 4)
            for index in pixels.indices {
                let offset = index * 4, coverage = pixels[index]
                bytes[offset] = coverage; bytes[offset+1] = coverage; bytes[offset+2] = coverage; bytes[offset+3] = coverage
            }
        }
        return Bitmap(bytes: bytes, width: width, height: height, padding: padding, colored: colored)
    }

    static func isPrivateUse(_ scalar: UInt32) -> Bool {
        (0xe000...0xf8ff).contains(scalar) || (0xf0000...0xffffd).contains(scalar) || (0x100000...0x10fffd).contains(scalar)
    }
}
