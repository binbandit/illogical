import AppKit
import SwiftUI

enum TerminalThemeColor: Codable, Equatable {
    case rgb(UInt32), cellForeground, cellBackground, windowForeground, windowBackground

    func resolve(foreground: UInt32, background: UInt32, windowForeground: UInt32 = 0xffffff, windowBackground: UInt32 = 0) -> UInt32 {
        switch self {
        case .rgb(let value): return value
        case .cellForeground: return foreground
        case .cellBackground: return background
        case .windowForeground: return windowForeground
        case .windowBackground: return windowBackground
        }
    }
}

struct TerminalTheme: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var background: UInt32
    var foreground: UInt32
    var accent: UInt32
    var ansi: [UInt32]
    var isLight: Bool
    // Optional so themes saved by earlier versions retain their existing look.
    var extendedPalette: [UInt32]? = nil
    var selectionForeground: TerminalThemeColor? = nil
    var selectionBackground: TerminalThemeColor? = nil
    var cursorText: TerminalThemeColor? = nil
    var cursorColor: TerminalThemeColor? = nil
    var minimumContrast: Double? = nil
    var backgroundOpacity: Double? = nil
    var backgroundOpacityCells: Bool? = nil

    var palette: [UInt32] {
        var values = Array(ansi.prefix(16))
        while values.count < 16 { values.append(foreground) }
        if let extendedPalette, extendedPalette.count == 240 {
            values.append(contentsOf: extendedPalette)
            return values
        }
        let levels: [UInt32] = [0, 95, 135, 175, 215, 255]
        for r in levels { for g in levels { for b in levels { values.append(r << 16 | g << 8 | b) } } }
        for i in 0..<24 { let v = UInt32(8 + i * 10); values.append(v << 16 | v << 8 | v) }
        return values
    }
    var wire: WireTheme { WireTheme(background: background, foreground: foreground, cursor: accent, palette: palette) }
    var effectiveBackgroundOpacity: Double {
        guard let opacity = backgroundOpacity, opacity.isFinite else { return 1 }
        return min(1, max(0, opacity))
    }
    var color: Color { Color(hex: background) }
    var text: Color { Color(hex: foreground) }
    var tint: Color { Color(hex: accent) }
    var chrome: Color { Color(hex: background).mix(with: isLight ? .black : .white, by: isLight ? 0.025 : 0.035) }
    var border: Color { text.opacity(isLight ? 0.12 : 0.11) }

    static let darkANSI: [UInt32] = [0x202124, 0xeb777b, 0x8fbc8f, 0xe3c184, 0x8daeda, 0xbc9bd6, 0x89c3ca, 0xdadce2, 0x6f747d, 0xf3999c, 0xa7d4a4, 0xf1d8a2, 0xaec7ed, 0xd2b6e7, 0xa4d7dc, 0xf2f3f5]
    static let lightANSI: [UInt32] = [0x41454e, 0xa54655, 0x517456, 0x927136, 0x4b70a8, 0x885ba7, 0x407b83, 0xd5d9df, 0x747987, 0xbc5365, 0x628a62, 0xac843c, 0x6086bc, 0x9a70b9, 0x5c949c, 0xf9f9fc]
    static let merinoDark = TerminalTheme(name: "Merino Dark", background: 0x1d1e20, foreground: 0xdcdde1, accent: 0x9db9df, ansi: darkANSI, isLight: false)
    static let merinoLight = TerminalTheme(name: "Merino Light", background: 0xf7f7fa, foreground: 0x454650, accent: 0x6b84b8, ansi: lightANSI, isLight: true)

    // The names are documented in previews; colors are our reconstructions.
    // Imported Ghostty themes retain their actual configured color values.
    static let builtins: [TerminalTheme] = {
        let dark: [(String, UInt32, UInt32, UInt32)] = [
            ("Abyssal Trench",0x111e2b,0xc9dce6,0x82bec8), ("Basalt Shore",0x212326,0xd1d3d5,0xadb7c2),
            ("Cathode Amber",0x201c15,0xe9c087,0xf0b765), ("Charcoal Atelier",0x232124,0xd9d0d6,0xc9a8b9),
            ("Cinder Peak",0x251f1e,0xe1d0c8,0xd8a08a), ("Cobalt Foundry",0x17213a,0xd0d9ef,0x86a8f0),
            ("Ember Hollow",0x241b18,0xe3cbbc,0xe7a77d), ("Heliotrope Haze",0x251c30,0xdfcdec,0xbb9bd9),
            ("Ink Meridian",0x161b27,0xd0d8e8,0x89a6d8), ("Juniper Smoke",0x1b2522,0xcbded4,0x92b7a2),
            ("Midnight Tundra",0x171e25,0xcbd7df,0x8bacbd), ("Misty Forest",0x1a2625,0xc7dcd2,0x9abdaa),
            ("Moss Cathedral",0x20271d,0xd4ddc8,0xb4c69a), ("Neon Arcade",0x211831,0xddd0ee,0xc7a3ef),
            ("Nocturne Rose",0x281e28,0xe0cbd9,0xd6a2bd), ("Oxidized Library",0x24271e,0xd4d8bd,0xb4bd8d),
            ("Petrol Lagoon",0x132a30,0xc5dfdf,0x8ec4c5), ("Phosphor Archive",0x14231c,0xbfdec8,0x8dcaa2),
            ("Polar Aurora",0x17252c,0xcbdfe6,0x92c3d6), ("Roasted Umber",0x28221e,0xe1d5c6,0xc9ad89),
            ("Saffron Nightfall",0x29241c,0xe1d5b4,0xe2c27a), ("Silver Point Dark",0x25252a,0xdad9e1,0xb0afd0),
            ("Sonoran Dusk",0x2b2328,0xe4d0d3,0xd9aaa6), ("Static Noir",0x171719,0xd8d8dd,0xb5b5cc),
            ("Velvet Dusk",0x291f32,0xe0cee7,0xc5a2d4)
        ]
        let light: [(String, UInt32, UInt32)] = [
            ("Alpine Milk",0xf2f6f4,0x648276), ("Buttercream Diner",0xfaf4e6,0x9d8050),
            ("Coastal Linen",0xf5f4ee,0x668893), ("Glacier Mint",0xebf5f0,0x538878),
            ("Ivory Gallery",0xf8f5ed,0x8b7c69), ("Lavender Postcard",0xf3eff8,0x8b73ab),
            ("Newsprint Fog",0xeeefef,0x67788b), ("Orchard Breeze",0xf1f5e9,0x75844b),
            ("Peach Veranda",0xfcf0e9,0xae7b62), ("Porcelain Morning",0xf9f9f4,0x777f9b),
            ("Silver Point Light",0xf0f0f5,0x7c79a8), ("Sunlit Parchment",0xf8f2df,0xa38343),
            ("Terracotta Noon",0xf7eae1,0xad725b), ("Whitby Bay",0xeff4f6,0x60849a)
        ]
        return [merinoDark, merinoLight] + dark.map { TerminalTheme(name:$0.0,background:$0.1,foreground:$0.2,accent:$0.3,ansi:darkANSI,isLight:false) } + light.map { TerminalTheme(name:$0.0,background:$0.1,foreground:0x454650,accent:$0.2,ansi:lightANSI,isLight:true) }
    }()
}

enum InterfaceStyle: String, CaseIterable, Codable { case modern = "Modern", system = "System", themed = "Themed", blended = "Blended" }
enum Density: String, CaseIterable, Codable { case comfortable = "Comfortable", compact = "Compact" }

extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}

extension NSColor {
    convenience init(hex: UInt32) { self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1) }
}
