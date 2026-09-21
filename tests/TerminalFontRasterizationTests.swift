import AppKit
import CoreText

@main struct TerminalFontRasterizationTests {
    @MainActor static func main() {
        let url = URL(fileURLWithPath: "illogical/Resources/Fonts/JetBrainsMonoNerdFont-Regular.ttf")
        guard let provider = CGDataProvider(url: url as CFURL), let bundled = CGFont(provider) else {
            fatalError("Bundled JetBrains Mono fixture is missing")
        }
        var combinations = 0
        for size: CGFloat in [12, 13, 14] {
            for font in [NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
                         CTFontCreateWithGraphicsFont(bundled, size, nil, nil) as NSFont] {
                for scale: CGFloat in [1, 2] {
                    let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
                    let cell = NSSize(width: round(advance * scale) / scale,
                                      height: ceil(font.ascender - font.descender + font.leading + 3))
                    let raster = TerminalFontRasterizer(font: font, scale: scale, cell: cell,
                                                        options: .init(features: ["calt": 0, "liga": 0]))
                    precondition(CTFontGetSize(raster.resolvedFont(for: "M")) == size * scale,
                                 "Device scale changed the requested point size")
                    for (bold, italic) in [(false, false), (true, false), (false, true)] {
                        let text = String(repeating: "|", count: 12)
                        let grouped = raster.rasterize(.init(text: text, bold: bold, italic: italic, width: 12))!
                        let single = raster.rasterize(.init(text: "|", bold: bold, italic: italic, width: 1))!
                        var expected = [UInt8](repeating: 0, count: grouped.bytes.count)
                        let step = Int(round(cell.width * scale))
                        for column in 0..<12 {
                            for y in 0..<single.height {
                                for x in 0..<single.width {
                                    let source = (y * single.width + x) * 4
                                    let destination = (y * grouped.width + x + column * step) * 4
                                    let alpha = Int(single.bytes[source + 3])
                                    for component in 0..<4 {
                                        expected[destination + component] = UInt8(min(255, Int(single.bytes[source + component])
                                            + (Int(expected[destination + component]) * (255 - alpha) + 127) / 255))
                                    }
                                }
                            }
                        }
                        precondition(grouped.bytes == expected,
                                     "Grouping operators distorted glyph pixels: \(font.fontName) \(size)pt \(scale)x bold=\(bold) italic=\(italic)")
                        combinations += 1
                    }
                }
            }
        }
        let variableURL = URL(fileURLWithPath: ".build/dependencies/ghostty/src/font/res/Lilex-VF.ttf")
        guard let provider = CGDataProvider(url: variableURL as CFURL), let graphicsFont = CGFont(provider) else {
            fatalError("Run scripts/bootstrap.sh to obtain the pinned ligature fixture")
        }
        let font = CTFontCreateWithGraphicsFont(graphicsFont, 13, nil, nil) as NSFont
        for scale: CGFloat in [1, 2] {
            let cell = NSSize(width: round(font.maximumAdvancement.width * scale) / scale, height: 19)
            let enabled = TerminalFontRasterizer(font: font, scale: scale, cell: cell,
                                                 options: .init(features: ["calt": 1, "liga": 1]))
            let disabled = TerminalFontRasterizer(font: font, scale: scale, cell: cell,
                                                  options: .init(features: ["calt": 0, "liga": 0]))
            let key = TerminalFontRasterizer.Key(text: "==>", bold: false, italic: false, width: 3)
            let ligature = enabled.rasterize(key)!, separate = disabled.rasterize(key)!
            precondition(ligature.bytes != separate.bytes, "Grid alignment disabled code ligatures at \(scale)x")
            precondition(ligature.bytes.contains { $0 != 0 }, "Ligature is empty")
        }
        print("PASS: \(combinations) SF Mono/JetBrains operator raster combinations at 12/13/14pt, 1x/2x match individual cells exactly; Lilex ligatures remain enabled")
    }
}
