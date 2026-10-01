import AppKit
import Observation

/// App-wide settings shared by every window and persisted in the app's
/// defaults. Keys match earlier releases so existing preferences carry over.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    static let fontSizes: ClosedRange<Double> = 6...72

    var themeName: String { didSet { defaults.set(themeName, forKey: Key.theme) } }
    var followSystemAppearance: Bool {
        didSet { defaults.set(followSystemAppearance, forKey: Key.followSystemAppearance); applySystemAppearance() }
    }
    var lightThemeName: String { didSet { defaults.set(lightThemeName, forKey: Key.lightTheme); applySystemAppearance() } }
    var darkThemeName: String { didSet { defaults.set(darkThemeName, forKey: Key.darkTheme); applySystemAppearance() } }
    private(set) var importedThemes: [TerminalTheme] { didSet { save(importedThemes, forKey: Key.importedThemes) } }
    var interfaceStyle: InterfaceStyle { didSet { defaults.set(interfaceStyle.rawValue, forKey: Key.interfaceStyle) } }
    var density: Density { didSet { defaults.set(density.rawValue, forKey: Key.density) } }
    var verticalTabs: Bool { didSet { defaults.set(verticalTabs, forKey: Key.verticalTabs) } }
    var showPaneTitles: Bool { didSet { defaults.set(showPaneTitles, forKey: Key.showPaneTitles) } }
    /// Opacity of panes that do not have focus, like Ghostty's `unfocused-split-opacity`.
    var unfocusedPaneOpacity: Double { didSet { defaults.set(unfocusedPaneOpacity, forKey: Key.unfocusedPaneOpacity) } }
    var fontName: String { didSet { defaults.set(fontName, forKey: Key.fontName) } }
    /// The configured size. Windows zoom relative to it without changing it.
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: Key.fontSize) } }
    var fontOptions: TerminalFontOptions { didSet { save(fontOptions, forKey: Key.fontOptions) } }
    var contrastCorrection: Bool { didSet { defaults.set(contrastCorrection, forKey: Key.contrastCorrection) } }
    var copyOnSelection: Bool { didSet { defaults.set(copyOnSelection, forKey: Key.copyOnSelection) } }
    var synchronizeViewports: Bool { didSet { defaults.set(synchronizeViewports, forKey: Key.synchronizeViewports) } }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?

    var themes: [TerminalTheme] { TerminalTheme.builtins + importedThemes }
    var theme: TerminalTheme { themes.first { $0.name == themeName } ?? .merinoDark }

    private init() {
        themeName = Self.storedTheme(Key.theme, in: defaults) ?? TerminalTheme.merinoDark.name
        followSystemAppearance = defaults.bool(forKey: Key.followSystemAppearance)
        lightThemeName = Self.storedTheme(Key.lightTheme, in: defaults) ?? TerminalTheme.merinoLight.name
        darkThemeName = Self.storedTheme(Key.darkTheme, in: defaults) ?? TerminalTheme.merinoDark.name
        importedThemes = Self.load([TerminalTheme].self, from: defaults, forKey: Key.importedThemes) ?? []
        interfaceStyle = defaults.string(forKey: Key.interfaceStyle).flatMap(InterfaceStyle.init) ?? .themed
        density = defaults.string(forKey: Key.density).flatMap(Density.init) ?? .compact
        verticalTabs = defaults.bool(forKey: Key.verticalTabs)
        showPaneTitles = defaults.bool(forKey: Key.showPaneTitles)
        // Unfocused panes take the chrome's darker surface instead; this
        // Ghostty fade is opt-in through the setting or a Ghostty import.
        unfocusedPaneOpacity = defaults.object(forKey: Key.unfocusedPaneOpacity) as? Double ?? 1
        fontName = defaults.string(forKey: Key.fontName) ?? TerminalFontOptions.defaultFontName
        fontSize = defaults.object(forKey: Key.fontSize) as? Double ?? Double(TerminalFontOptions.defaultFontSize)
        fontOptions = Self.load(TerminalFontOptions.self, from: defaults, forKey: Key.fontOptions) ?? .defaults
        contrastCorrection = defaults.object(forKey: Key.contrastCorrection) as? Bool ?? true
        copyOnSelection = defaults.bool(forKey: Key.copyOnSelection)
        synchronizeViewports = defaults.bool(forKey: Key.synchronizeViewports)
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.applySystemAppearance() }
        }
        applySystemAppearance()
    }

    /// Picks a theme explicitly, which stops following the system appearance.
    func selectTheme(_ name: String) {
        followSystemAppearance = false
        themeName = name
    }

    func applySystemAppearance() {
        guard followSystemAppearance else { return }
        let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let name = dark ? darkThemeName : lightThemeName
        if themeName != name, themes.contains(where: { $0.name == name }) { themeName = name }
    }

    /// Adds imported themes, replacing same-named ones. A light/dark pair
    /// follows the system appearance; a single theme is selected directly.
    func adopt(_ imported: [TerminalTheme]) {
        guard let first = imported.first else { return }
        importedThemes.removeAll { old in imported.contains { $0.name == old.name } }
        importedThemes.append(contentsOf: imported)
        if let light = imported.first(where: \.isLight), let dark = imported.first(where: { !$0.isLight }) {
            lightThemeName = light.name
            darkThemeName = dark.name
            followSystemAppearance = true
        } else {
            selectTheme(first.name)
        }
    }

    /// Applies Ghostty's font family, size, features and appearance-related
    /// pane settings. Keybindings and unrelated settings are ignored.
    func importGhosttyFont(locations: GhosttyThemeImporter.Locations = .current) throws {
        let entries = try GhosttyThemeImporter.configurationEntries(locations: locations)
        func last(_ key: String) -> String? { entries.last { $0.0 == key }?.1 }
        if let name = last("font-family"), !name.isEmpty { fontName = name }
        if let size = last("font-size").flatMap(Double.init), Self.fontSizes.contains(size) { fontSize = size }
        if let opacity = last("unfocused-split-opacity").flatMap(Double.init), opacity.isFinite {
            unfocusedPaneOpacity = min(1, max(0.15, opacity))
        }
        fontOptions = TerminalFontOptions.importGhostty(entries: entries)
    }

    private func save<Value: Encodable>(_ value: Value, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    /// A saved theme name, following built-in themes that were renamed.
    private static func storedTheme(_ key: String, in defaults: UserDefaults) -> String? {
        defaults.string(forKey: key).map { TerminalTheme.renamed[$0] ?? $0 }
    }

    private static func load<Value: Decodable>(_ type: Value.Type, from defaults: UserDefaults, forKey key: String) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private enum Key {
        static let theme = "theme"
        static let followSystemAppearance = "followSystemAppearance"
        static let lightTheme = "lightTheme"
        static let darkTheme = "darkTheme"
        static let importedThemes = "importedThemes"
        static let interfaceStyle = "interfaceStyle"
        static let density = "density"
        static let verticalTabs = "verticalTabs"
        static let showPaneTitles = "showPaneTitles"
        static let unfocusedPaneOpacity = "unfocusedPaneOpacity"
        static let fontName = "fontName"
        static let fontSize = "fontSize"
        static let fontOptions = "fontOptions"
        static let contrastCorrection = "contrastCorrection"
        static let copyOnSelection = "copyOnSelection"
        static let synchronizeViewports = "synchronizeViewports"
    }
}
