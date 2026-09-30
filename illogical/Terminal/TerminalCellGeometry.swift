import CoreGraphics

/// Typed views of the packed cell fields that Bridge.c extracts from libghostty.
extension ILCell {
    struct Flags: OptionSet {
        let rawValue: UInt8
        static let bold = Flags(rawValue: 1 << 0)
        static let italic = Flags(rawValue: 1 << 1)
        static let underline = Flags(rawValue: 1 << 2)
        static let selected = Flags(rawValue: 1 << 3)
        static let strikethrough = Flags(rawValue: 1 << 4)
        static let overline = Flags(rawValue: 1 << 5)
        static let searchMatch = Flags(rawValue: 1 << 6)
        static let searchSelected = Flags(rawValue: 1 << 7)

        static let decorations: Flags = [.underline, .strikethrough, .overline]
        static let highlights: Flags = [.selected, .searchMatch, .searchSelected]
    }

    struct Attributes: OptionSet {
        let rawValue: UInt8
        static let underlineColor = Attributes(rawValue: 1 << 0)
        static let invisible = Attributes(rawValue: 1 << 1)
        static let blink = Attributes(rawValue: 1 << 2)
        static let explicitBackground = Attributes(rawValue: 1 << 3)
        static let inverse = Attributes(rawValue: 1 << 4)
    }

    /// SGR 4 subparameters, in libghostty's order.
    enum UnderlineStyle: UInt8 {
        case none, single, double, curly, dotted, dashed
    }

    var styleFlags: Flags { Flags(rawValue: flags) }
    var styleAttributes: Attributes { Attributes(rawValue: attributes) }
    var underline: UnderlineStyle { UnderlineStyle(rawValue: underlineStyle) ?? .single }

    /// UTF-8 length of the first scalar, or 0 for an empty cell.
    private var firstScalarLength: Int {
        let lead = UInt8(bitPattern: text.0)
        switch lead {
        case 0: return 0
        case ..<0xc0: return 1
        case ..<0xe0: return 2
        case ..<0xf0: return 3
        default: return 4
        }
    }

    /// The first Unicode scalar, decoded without allocating a String.
    var firstScalar: UInt32 {
        let lead = UInt32(UInt8(bitPattern: text.0))
        func continuation(_ byte: CChar) -> UInt32 { UInt32(UInt8(bitPattern: byte)) & 0x3f }
        switch firstScalarLength {
        case 0: return 0
        case 1: return lead
        case 2: return (lead & 0x1f) << 6 | continuation(text.1)
        case 3: return (lead & 0x0f) << 12 | continuation(text.1) << 6 | continuation(text.2)
        default: return (lead & 0x07) << 18 | continuation(text.1) << 12 | continuation(text.2) << 6 | continuation(text.3)
        }
    }

    /// True when the cell holds exactly one scalar (no combining marks or ZWJ).
    var isSingleScalar: Bool {
        switch firstScalarLength {
        case 0: return false
        case 1: return text.1 == 0
        case 2: return text.2 == 0
        case 3: return text.3 == 0
        default: return text.4 == 0
        }
    }

    /// Empty cells and plain spaces draw no glyph.
    var isBlank: Bool { text.0 == 0 || (text.0 == 0x20 && text.1 == 0) }

    var string: String {
        withUnsafePointer(to: text) { $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: text)) { String(cString: $0) } }
    }
}

extension ILFrame {
    var cursorShape: TerminalCursorStyle { TerminalCursorStyle(rawValue: Int(cursorStyle)) ?? .block }
}

/// Block elements (U+2580-U+259F) are drawn as exact cell-fraction rectangles
/// instead of font glyphs, so adjacent cells tile without seams.
enum TerminalBlockElements {
    static let range: ClosedRange<UInt32> = 0x2580...0x259f

    /// Rectangles in fractions of the cell, top-left origin.
    static func rects(_ scalar: UInt32) -> [CGRect] { table[Int(scalar - range.lowerBound)] }

    /// Shades fill the whole cell with partial foreground coverage, like Ghostty.
    static func alpha(_ scalar: UInt32) -> Float {
        switch scalar {
        case 0x2591: 0.25
        case 0x2592: 0.5
        case 0x2593: 0.75
        default: 1
        }
    }

    private static let table: [[CGRect]] = range.map { scalar in
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        switch scalar {
        case 0x2580: return [CGRect(x: 0, y: 0, width: 1, height: 0.5)]
        case 0x2581...0x2588:
            let height = Double(scalar - 0x2580) / 8
            return [CGRect(x: 0, y: 1 - height, width: 1, height: height)]
        case 0x2589...0x258f: return [CGRect(x: 0, y: 0, width: Double(0x2590 - scalar) / 8, height: 1)]
        case 0x2590: return [CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        case 0x2591...0x2593: return [full]
        case 0x2594: return [CGRect(x: 0, y: 0, width: 1, height: 0.125)]
        case 0x2595: return [CGRect(x: 0.875, y: 0, width: 0.125, height: 1)]
        default:
            // Quadrants: bit 0 upper left, 1 upper right, 2 lower left, 3 lower right.
            let quadrants: [UInt32: Int] = [0x2596: 4, 0x2597: 8, 0x2598: 1, 0x2599: 13, 0x259a: 9,
                                            0x259b: 7, 0x259c: 11, 0x259d: 2, 0x259e: 6, 0x259f: 14]
            let mask = quadrants[scalar] ?? 0
            return (0..<4).compactMap { index in
                mask & (1 << index) != 0 ? CGRect(x: Double(index % 2) / 2, y: Double(index / 2) / 2, width: 0.5, height: 0.5) : nil
            }
        }
    }
}
