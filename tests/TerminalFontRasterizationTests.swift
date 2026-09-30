import AppKit
import CoreText

/// A coverage canvas that places trimmed bitmaps relative to a shared cell origin.
private struct Composite: Equatable {
    let width: Int, height: Int
    var pixels: [UInt8]
    let origin: (x: Int, y: Int)

    init(width: Int, height: Int, origin: (x: Int, y: Int)) {
        self.width = width; self.height = height; self.origin = origin
        pixels = [UInt8](repeating: 0, count: width * height)
    }

    /// Source-over compositing of coverage, like the GPU's premultiplied blend.
    mutating func draw(_ bitmap: TerminalFontRasterizer.Bitmap, x offset: Int) {
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let target = (origin.y + bitmap.top + y) * width + origin.x + bitmap.left + offset + x
                let source = Int(bitmap.pixels[y * bitmap.width + x])
                pixels[target] = UInt8(min(255, source + (Int(pixels[target]) * (255 - source) + 127) / 255))
            }
        }
    }

    static func == (lhs: Composite, rhs: Composite) -> Bool { lhs.pixels == rhs.pixels }
}

@main struct TerminalFontRasterizationTests {
    @MainActor static func main() {
        let url = URL(fileURLWithPath: "illogical/Resources/Fonts/JetBrainsMonoNerdFont-Regular.ttf")
        guard let provider = CGDataProvider(url: url as CFURL), let bundled = CGFont(provider) else {
            fatalError("Bundled JetBrains Mono fixture is missing")
        }
        var combinations = 0
        for size: CGFloat in [12, 13, 14] {
            for font in [NSFont.monospacedSystemFont(ofSize: size, weight: .regular), CTFontCreateWithGraphicsFont(bundled, size, nil, nil) as NSFont] {
                for scale: CGFloat in [1, 2] {
                    let raster = TerminalFontRasterizer(font: font, scale: scale, options: .init(features: ["calt": 0, "liga": 0]))
                    precondition(CTFontGetSize(raster.resolvedFont(for: "M")) == size * scale, "Device scale changed the requested point size")
                    let step = raster.metrics.cellWidth, height = raster.metrics.cellHeight
                    for (bold, italic) in [(false, false), (true, false), (false, true)] {
                        let columns = 12
                        let grouped = raster.rasterize(.init(text: String(repeating: "|", count: columns), bold: bold, italic: italic, width: columns))!
                        let single = raster.rasterize(.init(text: "|", bold: bold, italic: italic))!
                        var expected = Composite(width: step * (columns + 4), height: height * 3, origin: (step * 2, height))
                        var actual = expected
                        for column in 0..<columns { expected.draw(single, x: column * step) }
                        actual.draw(grouped, x: 0)
                        precondition(actual == expected,
                                     "Grouping operators distorted glyph pixels: \(font.fontName) \(size)pt \(scale)x bold=\(bold) italic=\(italic)")
                        combinations += 1
                    }
                }
            }
        }
        let variableURL = URL(fileURLWithPath: ".build/dependencies/ghostty/src/font/res/Lilex-VF.ttf")
        guard let variableProvider = CGDataProvider(url: variableURL as CFURL), let graphicsFont = CGFont(variableProvider) else {
            fatalError("Run scripts/bootstrap.sh to obtain the pinned ligature fixture")
        }
        let font = CTFontCreateWithGraphicsFont(graphicsFont, 13, nil, nil) as NSFont
        for scale: CGFloat in [1, 2] {
            let enabled = TerminalFontRasterizer(font: font, scale: scale, options: .init(features: ["calt": 1, "liga": 1]))
            let disabled = TerminalFontRasterizer(font: font, scale: scale, options: .init(features: ["calt": 0, "liga": 0]))
            let key = TerminalFontRasterizer.Key(text: "==>", width: 3)
            let ligature = enabled.rasterize(key)!, separate = disabled.rasterize(key)!
            precondition(ligature.pixels != separate.pixels, "Grid alignment disabled code ligatures at \(scale)x")
            precondition(!ligature.isEmpty, "Ligature is empty")
        }
        print("PASS: \(combinations) SF Mono/JetBrains operator raster combinations at 12/13/14pt, 1x/2x match individual cells exactly; Lilex ligatures remain enabled")
    }
}
