import Foundation

struct TerminalFontOptions: Codable, Hashable {
    var features: [String: Int] = [:]
    var variations: [String: Double] = [:]
    var thicken = false
    var thickenStrength = 255
    static let defaults = TerminalFontOptions()

    static func importGhostty(entries: [(String, String)]) -> TerminalFontOptions {
        var options = TerminalFontOptions()
        for (key, value) in entries {
            switch key {
            case "font-thicken": options.thicken = value == "true"
            case "font-thicken-strength": if let strength = Int(value) { options.thickenStrength = max(0,min(255,strength)) }
            case "font-feature":
                if value.isEmpty { options.features.removeAll(); continue }
                for feature in value.split(separator: ",") {
                    let feature = feature.trimmingCharacters(in: .whitespacesAndNewlines)
                    let fields = feature.split(separator: "=", maxSplits: 1)
                    guard !fields.isEmpty else { continue }
                    var tag = String(fields[0]), enabled = fields.count == 2 ? Int(fields[1]) ?? 1 : 1
                    if tag.hasPrefix("-") { enabled = 0; tag.removeFirst() }
                    else if tag.hasPrefix("+") { tag.removeFirst() }
                    if tag.utf8.count == 4 { options.features[tag] = enabled }
                }
            case "font-variation":
                if value.isEmpty { options.variations.removeAll(); continue }
                for variation in value.split(separator: ",") {
                    let fields = variation.split(separator: "=", maxSplits: 1)
                    if fields.count == 2 {
                        let tag = fields[0].trimmingCharacters(in: .whitespaces)
                        if tag.utf8.count == 4, let value = Double(fields[1].trimmingCharacters(in: .whitespaces)) { options.variations[tag] = value }
                    }
                }
            default: break
            }
        }
        return options
    }
}
