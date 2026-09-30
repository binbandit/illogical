import Foundation

/// A Ghostty `adjust-*` value: a delta in device pixels or a percentage.
/// `adjust-cell-height = 10%` is `.percent(0.1)`; `2` is `.pixels(2)`.
enum TerminalMetricAdjustment: Codable, Hashable {
    case pixels(Int)
    case percent(Double)

    static let none = TerminalMetricAdjustment.pixels(0)

    /// Applies the delta to a pixel metric, rounding like Ghostty's `Modifier.apply`.
    func applied(to value: Int) -> Int {
        switch self {
        case .pixels(let delta): value + delta
        case .percent(let delta): Int((Double(value) * max(0, 1 + delta)).rounded())
        }
    }

    /// Parses Ghostty's syntax: an integer, or a number followed by `%`.
    init?(ghostty value: String) {
        let value = value.trimmingCharacters(in: .whitespaces)
        if value.hasSuffix("%") {
            guard let percent = Double(value.dropLast().trimmingCharacters(in: .whitespaces)), percent.isFinite else { return nil }
            self = .percent(percent / 100)
        } else {
            guard let pixels = Int(value) else { return nil }
            self = .pixels(pixels)
        }
    }
}

/// Cursor shapes, numbered like libghostty's `GhosttyRenderStateCursorVisualStyle`.
enum TerminalCursorStyle: Int, Codable, Hashable {
    case bar = 0
    case block = 1
    case underline = 2
    case blockHollow = 3
}

/// How 8-bit terminal colors are interpreted, like Ghostty's `window-colorspace`.
enum TerminalColorspace: String, Codable, Hashable {
    case srgb
    case displayP3 = "display-p3"
}

/// Ghostty-compatible text rendering preferences. Font identity (family and
/// size) is stored separately; everything here changes glyphs or cell metrics.
/// A plain `TerminalFontOptions()` has Ghostty's defaults; the app's own look
/// is `TerminalFontOptions.defaults`.
struct TerminalFontOptions: Codable, Hashable {
    var features: [String: Int] = [:]
    /// Variable-font axes such as `wght`, applied to the regular face.
    var variations: [String: Double] = [:]
    /// CoreText font smoothing, which renders glyphs heavier.
    var thicken = false
    var thickenStrength = 255
    /// Added to the font's natural line height.
    var cellHeight = TerminalMetricAdjustment.none
    /// Added to the 1px base thickness of bar, underline and hollow cursors.
    var cursorThickness = TerminalMetricAdjustment.none
    /// The shape used until a program selects one with DECSCUSR.
    var cursorStyle = TerminalCursorStyle.block
    /// Whether the default cursor blinks until a program selects otherwise.
    var cursorBlink = true
    var colorspace = TerminalColorspace.srgb

    init(features: [String: Int] = [:], variations: [String: Double] = [:], thicken: Bool = false, thickenStrength: Int = 255) {
        self.features = features
        self.variations = variations
        self.thicken = thicken
        self.thickenStrength = thickenStrength
    }

    // Preferences saved by earlier versions lack newer keys. Decode each key
    // independently so they keep their other settings.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        features = try container.decodeIfPresent([String: Int].self, forKey: .features) ?? defaults.features
        variations = try container.decodeIfPresent([String: Double].self, forKey: .variations) ?? defaults.variations
        thicken = try container.decodeIfPresent(Bool.self, forKey: .thicken) ?? defaults.thicken
        thickenStrength = try container.decodeIfPresent(Int.self, forKey: .thickenStrength) ?? defaults.thickenStrength
        cellHeight = try container.decodeIfPresent(TerminalMetricAdjustment.self, forKey: .cellHeight) ?? defaults.cellHeight
        cursorThickness = try container.decodeIfPresent(TerminalMetricAdjustment.self, forKey: .cursorThickness) ?? defaults.cursorThickness
        cursorStyle = try container.decodeIfPresent(TerminalCursorStyle.self, forKey: .cursorStyle) ?? defaults.cursorStyle
        cursorBlink = try container.decodeIfPresent(Bool.self, forKey: .cursorBlink) ?? defaults.cursorBlink
        colorspace = try container.decodeIfPresent(TerminalColorspace.self, forKey: .colorspace) ?? defaults.colorspace
    }

    /// Reads the rendering keys of a parsed Ghostty configuration. Keys absent
    /// from the configuration take Ghostty's defaults, not the app's.
    static func importGhostty(entries: [(String, String)]) -> TerminalFontOptions {
        var options = TerminalFontOptions()
        for (key, value) in entries {
            switch key {
            case "font-thicken": options.thicken = value == "true"
            case "font-thicken-strength":
                if let strength = Int(value) { options.thickenStrength = min(255, max(0, strength)) }
            case "font-feature":
                if value.isEmpty { options.features.removeAll(); continue }
                for feature in value.split(separator: ",") { options.addFeature(feature.trimmingCharacters(in: .whitespaces)) }
            case "font-variation":
                if value.isEmpty { options.variations.removeAll(); continue }
                for variation in value.split(separator: ",") {
                    let fields = variation.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if fields.count == 2, fields[0].utf8.count == 4, let axis = Double(fields[1]) { options.variations[fields[0]] = axis }
                }
            case "adjust-cell-height": options.cellHeight = TerminalMetricAdjustment(ghostty: value) ?? .none
            case "adjust-cursor-thickness": options.cursorThickness = TerminalMetricAdjustment(ghostty: value) ?? .none
            case "cursor-style":
                switch value {
                case "bar": options.cursorStyle = .bar
                case "underline": options.cursorStyle = .underline
                case "block_hollow": options.cursorStyle = .blockHollow
                default: options.cursorStyle = .block
                }
            // Ghostty blinks by default; only an explicit false disables it.
            case "cursor-style-blink": options.cursorBlink = value != "false"
            case "window-colorspace": options.colorspace = TerminalColorspace(rawValue: value) ?? .srgb
            default: break
            }
        }
        return options
    }

    /// Accepts `+tag`, `-tag`, `tag`, `tag=value` and `tag on/off` forms.
    private mutating func addFeature(_ feature: String) {
        var tag = Substring(feature), value = 1
        if tag.hasPrefix("-") { value = 0; tag = tag.dropFirst() }
        else if tag.hasPrefix("+") { tag = tag.dropFirst() }
        let fields = tag.split(whereSeparator: { $0 == "=" || $0 == " " }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = fields.first, name.utf8.count == 4 else { return }
        if fields.count == 2 {
            switch fields[1] {
            case "on", "true": value = 1
            case "off", "false": value = 0
            default: value = Int(fields[1]) ?? value
            }
        }
        features[name] = value
    }
}

/// The app's default terminal look, in one place. Saved preferences and
/// imported Ghostty settings override it, and every value applies live.
extension TerminalFontOptions {
    static let defaultFontName = "SF Mono"
    static let defaultFontSize: CGFloat = 13
    static let defaults: TerminalFontOptions = {
        var options = TerminalFontOptions()
        // Line height: 20% roomier than the font's own line spacing.
        options.cellHeight = .percent(0.2)
        // Glyph weight: `variations["wght"]` on variable fonts (the system
        // monospace face included), or `thicken` for any font.
        options.variations = [:]
        options.thicken = false
        options.cursorThickness = .pixels(2)
        options.cursorBlink = false
        return options
    }()
}
