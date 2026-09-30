import AppKit
import CoreText

/// Font options, Ghostty cell metrics and glyph rasterization. Pixel output of
/// the full Metal renderer is covered by display-text-test.swift.
@main
struct TerminalRenderingTest {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        testOptions()
        let bundledURL = root.appendingPathComponent("illogical/Resources/Fonts/JetBrainsMonoNerdFont-Regular.ttf")
        guard let provider = CGDataProvider(url: bundledURL as CFURL), let bundled = CGFont(provider) else {
            fatalError("Bundled JetBrains Mono fixture is missing")
        }
        let jetBrains = CTFontCreateWithGraphicsFont(bundled, 14, nil, nil) as NSFont
        testMetrics(jetBrains)
        testRasterization(jetBrains)
        testVariableFont(root)
        testCellDrawing()
        testBundledDefault()
        print("PASS: bundled JetBrains Mono default with real bold/italic, Ghostty option import, cell metrics and adjustments, thickening, synthetic bold, overhanging glyphs, variable weight, ligatures, Nerd Font fallback, marks, CJK, color emoji and aligned box drawing")
    }

    static func testOptions() {
        let owner: [(String, String)] = [
            ("font-variation", "wght=420"), ("font-feature", "+calt"), ("font-feature", "+zero"), ("font-feature", "-liga"),
            ("font-thicken", "true"), ("font-thicken-strength", "100"), ("adjust-cell-height", "10%"),
            ("cursor-style", "bar"), ("cursor-style-blink", "false"), ("adjust-cursor-thickness", "2"), ("window-colorspace", "display-p3")
        ]
        let imported = TerminalFontOptions.importGhostty(entries: owner)
        precondition(imported.features == ["calt": 1, "zero": 1, "liga": 0] && imported.variations == ["wght": 420])
        precondition(imported.thicken && imported.thickenStrength == 100)
        precondition(imported.cellHeight == .percent(0.1) && imported.cursorThickness == .pixels(2))
        precondition(imported.cursorStyle == .bar && !imported.cursorBlink && imported.colorspace == .displayP3)
        let ghosttyDefaults = TerminalFontOptions.importGhostty(entries: [])
        precondition(ghosttyDefaults.cellHeight == .none && ghosttyDefaults.cursorThickness == .none && ghosttyDefaults.cursorBlink,
                     "Keys absent from a Ghostty config take Ghostty's defaults")
        precondition(TerminalMetricAdjustment(ghostty: "-2") == .pixels(-2) && TerminalMetricAdjustment(ghostty: "25 %") == .percent(0.25))
        precondition(TerminalMetricAdjustment.percent(0.1).applied(to: 39) == 43 && TerminalMetricAdjustment.pixels(2).applied(to: 1) == 3)

        // Preferences saved before a key existed keep their other settings.
        let legacy = Data(#"{"features":{"calt":1},"variations":{},"thicken":true,"thickenStrength":80}"#.utf8)
        let decoded = try! JSONDecoder().decode(TerminalFontOptions.self, from: legacy)
        precondition(decoded.thicken && decoded.thickenStrength == 80 && decoded.features == ["calt": 1])
        precondition(decoded.cellHeight == TerminalFontOptions.defaults.cellHeight && decoded.cursorStyle == .block)
        let roundTrip = try! JSONDecoder().decode(TerminalFontOptions.self, from: JSONEncoder().encode(imported))
        precondition(roundTrip == imported)
    }

    @MainActor static func testMetrics(_ font: NSFont) {
        for scale: CGFloat in [1, 2] {
            let sized = CTFontCreateCopyWithAttributes(font as CTFont, 14 * scale, nil, nil)
            var natural = TerminalFontOptions.importGhostty(entries: [])
            let plain = TerminalCellMetrics(font: sized, options: natural)
            let lineHeight = CTFontGetAscent(sized) + CTFontGetDescent(sized) + CTFontGetLeading(sized)
            precondition(plain.cellHeight == Int(lineHeight.rounded()), "Cell height must be the rounded line height, like Ghostty")
            precondition(plain.cursorHeight == plain.cellHeight && plain.cursorThickness == 1)
            precondition(plain.underlinePosition > plain.cellHeight - plain.baseline, "Underlines sit below the baseline")
            precondition(plain.strikethroughPosition < plain.cellHeight - plain.baseline, "Strikethrough sits above the baseline")
            natural.cellHeight = .percent(0.1)
            natural.cursorThickness = .pixels(2)
            let adjusted = TerminalCellMetrics(font: sized, options: natural)
            let added = adjusted.cellHeight - plain.cellHeight
            precondition(adjusted.cellHeight == Int((Double(plain.cellHeight) * 1.1).rounded()) && added > 0)
            precondition(adjusted.baseline - plain.baseline + (adjusted.underlinePosition - plain.underlinePosition) == added,
                         "Added height must be split between the top and bottom of the cell")
            precondition(abs((adjusted.baseline - plain.baseline) - (adjusted.underlinePosition - plain.underlinePosition)) <= 1,
                         "Adjusted text must stay vertically centered")
            precondition(adjusted.cursorHeight == plain.cellHeight && adjusted.cursorTop == added / 2,
                         "Cursors keep the font's height, centered in the taller cell")
            precondition(adjusted.cursorThickness == 3 && adjusted.cellWidth == plain.cellWidth)
        }
    }

    @MainActor static func testRasterization(_ font: NSFont) {
        func coverage(_ bitmap: TerminalFontRasterizer.Bitmap) -> Int { bitmap.pixels.reduce(0) { $0 + Int($1) } }
        let plain = TerminalFontRasterizer(font: font, scale: 2)
        let regular = plain.rasterize(.init(text: "M"))!
        let thick = TerminalFontRasterizer(font: font, scale: 2, options: .init(thicken: true)).rasterize(.init(text: "M"))!
        let lighter = TerminalFontRasterizer(font: font, scale: 2, options: .init(thicken: true, thickenStrength: 100)).rasterize(.init(text: "M"))!
        precondition(coverage(thick) > coverage(regular), "CoreText font thickening did not increase glyph coverage")
        precondition(coverage(lighter) < coverage(thick), "Font smoothing strength was ignored")
        // The bundled face has no bold style, like MonoLisaVariable Nerd Font.
        let bold = plain.rasterize(.init(text: "M", bold: true))!
        precondition(coverage(bold) > coverage(regular) * 11 / 10, "A family without bold must receive synthetic bold")
        let boldItalic = plain.rasterize(.init(text: "l", bold: true, italic: true))!
        let upright = plain.rasterize(.init(text: "l", bold: true))!
        precondition(boldItalic.pixels != upright.pixels, "Bold italic must stay italic when only a bold face is missing")

        // Stacked marks exceed the ascent; they overhang instead of being clipped.
        let stacked = plain.rasterize(.init(text: "A\u{30a}\u{301}"))!
        precondition(stacked.top < 0, "Glyphs taller than the cell must not be clipped at its top edge")
        let descender = plain.rasterize(.init(text: "g"))!
        precondition(descender.top + descender.height > plain.metrics.cellHeight - plain.metrics.baseline,
                     "Descenders must extend below the baseline")

        for text in ["\u{f115}", "\u{f120}", "\u{f013}", "\u{f1e0}", "\u{f0001}"] {
            let chosen = plain.resolvedFont(for: text)
            precondition(text.unicodeScalars.allSatisfy { CFCharacterSetIsLongCharacterMember(CTFontCopyCharacterSet(chosen), $0.value) },
                         "Missing Nerd Font glyph: \(text)")
        }
        let system = TerminalFontRasterizer(font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), scale: 2)
        for (text, width) in [("e\u{301}", 1), ("中", 2), ("👩🏽‍💻", 2), ("🇦🇺", 2), ("\u{f115}", 1)] {
            let bitmap = system.rasterize(.init(text: text, width: width))!
            precondition(!bitmap.isEmpty, "Empty glyph: \(text)")
            if text.unicodeScalars.first!.value > 0x1f000 { precondition(bitmap.colored, "Emoji lost its color font: \(text)") }
        }
        precondition(system.rasterize(.init(text: " "))!.isEmpty, "Blank glyphs must not occupy atlas space")
    }

    @MainActor static func testVariableFont(_ root: URL) {
        let url = root.appendingPathComponent(".build/dependencies/ghostty/src/font/res/Lilex-VF.ttf")
        guard let provider = CGDataProvider(url: url as CFURL), let graphicsFont = CGFont(provider) else {
            fatalError("Run scripts/bootstrap.sh to obtain the pinned variable-font test fixture")
        }
        let variable = CTFontCreateWithGraphicsFont(graphicsFont, 18, nil, nil) as NSFont
        let options = TerminalFontOptions.importGhostty(entries: [("font-variation", "wght=420")])
        let configured = TerminalFontRasterizer(font: variable, scale: 2, options: options)
        let variations = CTFontCopyVariation(configured.resolvedFont(for: "M"))! as NSDictionary
        precondition((variations[NSNumber(value: 0x77676874)] as? NSNumber)?.intValue == 420, "Weight variation was dropped")
        let on = TerminalFontRasterizer(font: variable, scale: 2, options: .init(features: ["calt": 1, "liga": 1]))
        let off = TerminalFontRasterizer(font: variable, scale: 2, options: .init(features: ["calt": 0, "liga": 0]))
        let key = TerminalFontRasterizer.Key(text: "==>", width: 3)
        precondition(on.rasterize(key)!.pixels != off.rasterize(key)!.pixels, "Code operator ligatures were not shaped")
    }

    /// The default family is the bundled JetBrains Mono, registered for this
    /// process, and its real bold and italic faces win over synthetic styles.
    @MainActor static func testBundledDefault() {
        precondition(TerminalBundledFonts.register(), "Bundled JetBrains Mono faces must register")
        guard let font = NSFont(name: TerminalFontOptions.defaultFontName, size: TerminalFontOptions.defaultFontSize) else {
            fatalError("The default family must resolve to the bundled font")
        }
        let raster = TerminalFontRasterizer(font: font, scale: 2)
        let faces = [(false, false, "JetBrainsMonoNF-Regular"), (true, false, "JetBrainsMonoNF-Bold"),
                     (false, true, "JetBrainsMonoNF-Italic"), (true, true, "JetBrainsMonoNF-BoldItalic")]
        for (bold, italic, name) in faces {
            let resolved = CTFontCopyPostScriptName(raster.resolvedFont(for: "M", bold: bold, italic: italic)) as String
            precondition(resolved == name, "bold=\(bold) italic=\(italic) resolved \(resolved), not the bundled \(name)")
        }
        precondition(NSFont(name: "Menlo", size: 13) != nil, "Installed families stay selectable")
    }

    /// Rounded corners must share the straight lines' pixel columns at 1x,
    /// where a half-pixel offset turns a 1px line into two gray ones.
    @MainActor static func testCellDrawing() {
        let raster = TerminalFontRasterizer(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), scale: 1)
        let vertical = raster.rasterize(.init(text: "│"))!, corner = raster.rasterize(.init(text: "╭"))!
        func columns(_ bitmap: TerminalFontRasterizer.Bitmap, row: Int) -> [Int] {
            (0..<bitmap.width).filter { bitmap.pixels[row * bitmap.width + $0] > 127 }.map { $0 + bitmap.left }
        }
        precondition(columns(corner, row: corner.height - 1) == columns(vertical, row: vertical.height - 1),
                     "╭ must meet │ on the same pixel column")
        precondition(vertical.top == 0 && vertical.height == raster.metrics.cellHeight, "Box drawing must span the full cell")
    }
}
