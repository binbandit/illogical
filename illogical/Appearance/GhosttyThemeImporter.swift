import Foundation

enum GhosttyThemeImporter {
    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // Injectable discovery makes the importer testable without changing a user's
    // Ghostty files. Import never creates Ghostty's default template/config.
    struct Locations {
        var home: URL
        var xdg: URL
        var applicationSupport: URL
        var resources: [URL]

        static var current: Locations {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let value = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? ""
            let xdg = value.hasPrefix("/") ? URL(fileURLWithPath: value) : home.appendingPathComponent(".config")
            return Locations(home: home, xdg: xdg.appendingPathComponent("ghostty"),
                applicationSupport: home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty"),
                resources: [URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty"),
                    home.appendingPathComponent("Applications/Ghostty.app/Contents/Resources/ghostty")])
        }

        var configurations: [URL] {
            [xdg.appendingPathComponent("config"), xdg.appendingPathComponent("config.ghostty"),
             applicationSupport.appendingPathComponent("config"), applicationSupport.appendingPathComponent("config.ghostty")]
        }
    }

    static func configurationEntries(locations: Locations = .current) throws -> [(String, String)] {
        let files = locations.configurations.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { throw ImportError(message: "No Ghostty configuration was found in your user folders.") }
        var entries: [(String, String)] = []
        var pending: [(URL, Bool)] = []
        func append(_ file: URL) throws {
            for (key, value) in try parse(file) {
                if key == "config-file" {
                    // An empty repeatable path clears pending includes, as in
                    // Ghostty. Includes are expanded relative to their own file.
                    if value.isEmpty { pending.removeAll(); continue }
                    let optional = value.hasPrefix("?")
                    let path = unquote(optional ? String(value.dropFirst()) : value)
                    guard !path.isEmpty else { continue }
                    pending.append((expand(path, relativeTo: file.deletingLastPathComponent(), home: locations.home), optional))
                } else { entries.append((key, value)) }
            }
        }
        for file in files { try append(file) }
        // Ghostty loads includes after all default files, breadth-first. Parsing
        // them inline changes which background/theme wins in common configs.
        var visited: Set<URL> = []
        var index = 0
        while index < pending.count {
            let (file, optional) = pending[index]; index += 1
            guard visited.insert(file.standardizedFileURL).inserted else { continue }
            if optional && !FileManager.default.fileExists(atPath: file.path) { continue }
            try append(file)
            guard visited.count <= 1_024 else { throw ImportError(message: "The Ghostty configuration includes too many files.") }
        }
        return entries
    }

    static func importConfiguration(locations: Locations = .current) throws -> [TerminalTheme] {
        let values = try configurationEntries(locations: locations)
        let themeValue = values.last(where: { $0.0 == "theme" })?.1 ?? ""
        let definitions = try themeNames(themeValue)
        var result: [TerminalTheme] = []
        for (name, light) in definitions {
            var themeEntries: [(String, String)] = []
            if !name.isEmpty {
                let files: [URL]
                if name.hasPrefix("/") || name.hasPrefix("~/") { files = [expand(name, relativeTo: locations.home, home: locations.home)] }
                else {
                    guard !name.contains("/") else { throw ImportError(message: "A Ghostty theme path must be absolute: \(name)") }
                    files = ([locations.xdg] + locations.resources).map { $0.appendingPathComponent("themes").appendingPathComponent(name) }
                }
                guard let file = files.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                    throw ImportError(message: "The Ghostty theme “\(name)” could not be found. Keep Ghostty installed so its bundled themes can be imported.")
                }
                // Ghostty deliberately ignores recursive theme/include entries
                // inside themes. Only the user's config can load other files.
                themeEntries = try parse(file).filter { $0.0 != "theme" && $0.0 != "config-file" }
            }
            var palette = [UInt32](repeating: 0, count: 256)
            il_palette_default(&palette)
            let defaults = palette
            var explicitlySet = [Bool](repeating: false, count: 256)
            var generate = false, harmonious = false
            var theme = TerminalTheme(name: "Ghostty · \(name.isEmpty ? "Custom" : name)", background: 0x282c34,
                foreground: 0xffffff, accent: 0xffffff, ansi: Array(palette.prefix(16)), isLight: false)
            theme.selectionForeground = .windowBackground
            theme.selectionBackground = .windowForeground
            theme.minimumContrast = 1
            theme.backgroundOpacity = 1
            theme.backgroundOpacityCells = false
            var cursor: TerminalThemeColor?
            for (key, value) in themeEntries + values {
                switch key {
                case "background": theme.background = try color(value, default: 0x282c34, key: key)
                case "foreground": theme.foreground = try color(value, default: 0xffffff, key: key)
                case "cursor-color": cursor = try terminalColor(value, key: key)
                case "cursor-text": theme.cursorText = try terminalColor(value, key: key)
                case "selection-foreground": theme.selectionForeground = try terminalColor(value, key: key) ?? .windowBackground
                case "selection-background": theme.selectionBackground = try terminalColor(value, key: key) ?? .windowForeground
                case "minimum-contrast": theme.minimumContrast = try number(value, default: 1, range: 1...21, key: key)
                case "background-opacity": theme.backgroundOpacity = try number(value, default: 1, range: 0...1, key: key)
                case "background-opacity-cells": theme.backgroundOpacityCells = try boolean(value, key: key)
                case "palette-generate": generate = try boolean(value, key: key)
                case "palette-harmonious": harmonious = try boolean(value, key: key)
                case "palette":
                    if value.isEmpty { palette = defaults; explicitlySet = [Bool](repeating: false, count: 256); continue }
                    var index: UInt8 = 0, rgb: UInt32 = 0
                    guard value.withCString({ il_palette_parse_entry($0, value.utf8.count, &index, &rgb) }) else { throw invalid(key, value) }
                    palette[Int(index)] = rgb; explicitlySet[Int(index)] = true
                default: break
                }
            }
            if generate { il_palette_generate(&palette, &explicitlySet, theme.background, theme.foreground, harmonious) }
            theme.ansi = Array(palette.prefix(16)); theme.extendedPalette = Array(palette.dropFirst(16))
            theme.accent = cursor?.resolve(foreground: theme.foreground, background: theme.background) ?? theme.foreground
            // Literal cursor colors travel through the terminal so OSC 12 can
            // override them. Cell-relative colors are resolved at presentation.
            if cursor == .cellForeground || cursor == .cellBackground { theme.cursorColor = cursor }
            theme.isLight = il_color_is_light(theme.background)
            if result.contains(where: { $0.name == theme.name }) { theme.name += light == true ? " Light" : " Dark" }
            result.append(theme)
        }
        return result
    }

    private static func themeNames(_ value: String) throws -> [(String, Bool?)] {
        guard value.contains(":"), !value.contains("=") else {
            if value.contains(",") || value.contains("=") { throw invalid("theme", value) }
            return [(value.trimmingCharacters(in: .whitespaces), nil)]
        }
        var definitions: [(String, Bool?)] = []
        for part in value.split(separator: ",", omittingEmptySubsequences: false) {
            let item = part.trimmingCharacters(in: .whitespaces)
            guard let colon = item.firstIndex(of: ":") else { throw invalid("theme", value) }
            let key = item[..<colon].trimmingCharacters(in: .whitespaces)
            let name = item[item.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard (key == "light" || key == "dark"), !name.isEmpty else { throw invalid("theme", value) }
            definitions.append((name, key == "light"))
        }
        guard definitions.count == 2, Set(definitions.map { $0.1 }).count == 2 else { throw invalid("theme", value) }
        return definitions
    }

    private static func parse(_ url: URL) throws -> [(String, String)] {
        let source = try String(contentsOf: url, encoding: .utf8)
        return source.components(separatedBy: .newlines).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            guard let split = line.firstIndex(of: "=") else { return (line, "true") }
            let key = line[..<split].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            return (key, unquote(value))
        }
    }

    private static func unquote(_ value: String) -> String {
        value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") ? String(value.dropFirst().dropLast()) : value
    }
    private static func expand(_ path: String, relativeTo directory: URL, home: URL) -> URL {
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL }
        return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)).standardizedFileURL
    }
    private static func invalid(_ key: String, _ value: String) -> ImportError {
        ImportError(message: "Invalid Ghostty \(key): \(value)")
    }
    private static func color(_ value: String, default fallback: UInt32, key: String) throws -> UInt32 {
        if value.isEmpty { return fallback }
        var rgb: UInt32 = 0
        guard value.withCString({ il_color_parse($0, value.utf8.count, &rgb) }) else { throw invalid(key, value) }
        return rgb
    }
    private static func terminalColor(_ value: String, key: String) throws -> TerminalThemeColor? {
        if value.isEmpty { return nil }
        if value == "cell-foreground" { return .cellForeground }
        if value == "cell-background" { return .cellBackground }
        return .rgb(try color(value, default: 0, key: key))
    }
    private static func number(_ value: String, default fallback: Double, range: ClosedRange<Double>, key: String) throws -> Double {
        if value.isEmpty { return fallback }
        guard let number = Double(value), number.isFinite else { throw invalid(key, value) }
        return min(range.upperBound, max(range.lowerBound, number))
    }
    private static func boolean(_ value: String, key: String) throws -> Bool {
        if value.isEmpty || value == "false" { return false }
        if value == "true" { return true }
        throw invalid(key, value)
    }
}
