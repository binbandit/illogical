import Foundation

@main
struct GhosttyThemeImportTests {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("illogical-theme-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let locations = GhosttyThemeImporter.Locations(home: root, xdg: root.appendingPathComponent("xdg/ghostty"),
            applicationSupport: root.appendingPathComponent("support"), resources: [root.appendingPathComponent("resources")])
        func write(_ url: URL, _ content: String) throws {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("Expected an invalid configuration to be rejected") } catch {}
        }
        rejects { _ = try GhosttyThemeImporter.importConfiguration(locations: locations) }
        let files = locations.configurations
        try write(files[0], "background=#111111\nconfig-file=first\nconfig-file=?missing\npalette=200=#010203\n")
        try write(files[1], "background=#222222\nconfig-file=second\n")
        try write(files[2], "background=#333333\n")
        try write(files[3], "background=#444444\n")
        try write(locations.xdg.appendingPathComponent("first"), "background=#555555\nconfig-file=grandchild\n")
        try write(locations.xdg.appendingPathComponent("second"), "background=#666666\n")
        try write(locations.xdg.appendingPathComponent("grandchild"), "background=#777777\nconfig-file=first\n")
        let entries = try GhosttyThemeImporter.configurationEntries(locations: locations)
        precondition(entries.filter { $0.0 == "background" }.map { $0.1 } == ["#111111", "#222222", "#333333", "#444444", "#555555", "#666666", "#777777"])
        var imported = try GhosttyThemeImporter.importConfiguration(locations: locations)[0]
        precondition(imported.background == 0x777777 && imported.palette[200] == 0x010203)
        precondition(imported.selectionForeground == .windowBackground && imported.selectionBackground == .windowForeground)
        precondition(imported.minimumContrast == 1 && imported.accent == 0xffffff)
        for file in files { try write(file, "") }
        let themeFile = locations.xdg.appendingPathComponent("themes/Named Theme")
        try write(themeFile, """
        # recursive paths in themes must be ignored
        config-file = nonexistent-required-file
        theme = nonexistent-theme
        background = #abc
        foreground = ForestGreen
        palette = 0xff=rgb:12/34/56
        palette = 0b10000=rgbi:1/0/0
        palette = 0o21=#123456
        cursor-color = cell-background
        cursor-text = cell-foreground
        selection-foreground = cell-background
        selection-background = rgb:aa/bb/cc
        minimum-contrast = 7
        background-opacity = 0.5
        background-opacity-cells = true
        """)
        try write(files[0], "theme=\"Named Theme\"\nforeground=#fedcba\n")
        imported = try GhosttyThemeImporter.importConfiguration(locations: locations)[0]
        precondition(imported.background == 0xaabbcc && imported.foreground == 0xfedcba)
        precondition(imported.palette[255] == 0x123456 && imported.palette[16] == 0xff0000 && imported.palette[17] == 0x123456)
        precondition(imported.cursorColor == .cellBackground && imported.cursorText == .cellForeground)
        precondition(imported.selectionForeground == .cellBackground && imported.selectionBackground == .rgb(0xaabbcc))
        precondition(imported.minimumContrast == 7 && imported.backgroundOpacity == 0.5 && imported.backgroundOpacityCells == true)
        precondition(imported.wire.palette == imported.palette && imported.wire.palette?.count == 256)
        let roundTrip = try JSONDecoder().decode(TerminalTheme.self, from: JSONEncoder().encode(imported))
        precondition(roundTrip == imported)
        let legacy = Data(#"{"name":"Old","background":0,"foreground":16777215,"accent":123,"ansi":[1,2],"isLight":false}"#.utf8)
        let decoded = try JSONDecoder().decode(TerminalTheme.self, from: legacy)
        precondition(decoded.extendedPalette == nil && decoded.minimumContrast == nil && decoded.effectiveBackgroundOpacity == 1 && decoded.palette.count == 256)

        try write(files[0], "theme=dark : Named Theme, light : Named Theme\nminimum-contrast=100\nbackground-opacity=-1\n")
        let pair = try GhosttyThemeImporter.importConfiguration(locations: locations)
        precondition(pair.count == 2 && pair[0].name != pair[1].name && pair.allSatisfy { $0.minimumContrast == 21 && $0.backgroundOpacity == 0 })
        for value in ["light:Named Theme", "light:Named Theme,light:Named Theme", "Named Theme,Other", "light=Named Theme,dark=Named Theme"] {
            try write(files[0], "theme=\(value)"); rejects { _ = try GhosttyThemeImporter.importConfiguration(locations: locations) }
        }
        for value in ["background=#abcd", "palette=256=#ffffff", "palette=-1=red", "background-opacity=nan", "minimum-contrast=inf", "background=red # no inline comments"] {
            try write(files[0], value); rejects { _ = try GhosttyThemeImporter.importConfiguration(locations: locations) }
        }
        for name in [themeFile.path, "~/xdg/ghostty/themes/Named Theme"] {
            try write(files[0], "theme=\(name)")
            let direct = try GhosttyThemeImporter.importConfiguration(locations: locations)[0]
            precondition(direct.background == 0xaabbcc)
        }
        try write(files[0], "config-file=missing-required"); rejects { _ = try GhosttyThemeImporter.importConfiguration(locations: locations) }
        try write(files[0], "config-file=missing-required\nconfig-file=\nbackground=black")
        let reset = try GhosttyThemeImporter.importConfiguration(locations: locations)[0]
        precondition(reset.background == 0)

        try write(files[0], "background=#f0e0d0\nforeground=#123456\npalette=200=#102030\npalette-generate=true\npalette-harmonious=true\n")
        imported = try GhosttyThemeImporter.importConfiguration(locations: locations)[0]
        var expected = [UInt32](repeating: 0, count: 256), mask = [Bool](repeating: false, count: 256)
        il_palette_default(&expected); expected[200] = 0x102030; mask[200] = true
        il_palette_generate(&expected, &mask, 0xf0e0d0, 0x123456, true)
        precondition(imported.palette == expected && expected[200] == 0x102030)
        precondition(TerminalThemeColor.cellForeground.resolve(foreground: 1, background: 2) == 1)
        precondition(TerminalThemeColor.cellBackground.resolve(foreground: 1, background: 2) == 2)
        precondition(TerminalThemeColor.windowForeground.resolve(foreground: 1, background: 2, windowForeground: 3) == 3)
        precondition(TerminalThemeColor.windowBackground.resolve(foreground: 1, background: 2, windowBackground: 4) == 4)
        precondition(ContrastCorrection.correct(0x777777, background: 0x777777, target: 0xffffff, minimumContrast: 1) == 0x777777)
        precondition(ContrastCorrection.correct(0xaaaaaa, background: 0, target: 0xffffff, minimumContrast: 21) == 0xffffff)
        precondition(ContrastCorrection.correct(0xaaaaaa, background: 0xffffff, target: 0, minimumContrast: 21) == 0)
        print("Theme import: ordered defaults, deferred breadth-first includes, cycles/optional/reset, exact Ghostty colors and 256-palette generation, light/dark validation, selection/cursor colors, contrast/opacity, wire palette, and backward Codable passed.")
    }
}
