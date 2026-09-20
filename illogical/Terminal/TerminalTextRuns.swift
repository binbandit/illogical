import CoreText
import Foundation

/// Contextual scripts need adjacent terminal cells to reach the shaper together.
/// ASCII, emoji and terminal graphics retain the existing per-cell fast path.
enum TerminalTextRuns {
    struct Cluster: Hashable {
        let utf16Offset: Int
        let utf16Count: Int
        let column: Int
        let width: Int
    }
    struct Run: Hashable {
        let text: String
        let clusters: [Cluster]
        let cellCount: Int
        let columns: Int
    }
    struct Cursor {
        let row: UInt16
        let column: UInt16
    }
    struct Glyph {
        let font: CTFont
        let id: CGGlyph
        let position: CGPoint
        let clusterColumn: Int
        let stringIndex: Int
    }

    static func requiresContext(_ scalar: UInt32) -> Bool {
        (0x0600...0x08ff).contains(scalar) || (0x0900...0x109f).contains(scalar)
            || (0x1780...0x18af).contains(scalar) || (0xa800...0xabff).contains(scalar)
            || (0x11000...0x11fff).contains(scalar) || (0x1e900...0x1e95f).contains(scalar)
    }

    private static func initialScalar(_ cell: ILCell) -> UInt32 {
        let first = UInt32(UInt8(bitPattern: cell.text.0))
        if first < 0x80 { return first }
        let second = UInt32(UInt8(bitPattern: cell.text.1)) & 0x3f
        if first < 0xe0 { return (first & 0x1f) << 6 | second }
        let third = UInt32(UInt8(bitPattern: cell.text.2)) & 0x3f
        if first < 0xf0 { return (first & 0xf) << 12 | second << 6 | third }
        return (first & 7) << 18 | second << 12 | third << 6 | UInt32(UInt8(bitPattern: cell.text.3)) & 0x3f
    }

    private static func sameStyle(_ first: ILCell, _ second: ILCell) -> Bool {
        first.foreground == second.foreground && first.background == second.background
            && first.flags == second.flags && first.underlineStyle == second.underlineStyle
            && first.underlineColor == second.underlineColor && first.attributes == second.attributes
    }

    static func plan(_ cells: UnsafeBufferPointer<ILCell>, at start: Int, cursor: Cursor? = nil,
                     maximumColumns: Int = 64, maximumUTF16: Int = 1024) -> Run? {
        guard cells.indices.contains(start) else { return nil }
        let first = cells[start]
        guard first.width > 0, requiresContext(initialScalar(first)) else { return nil }
        func cursorIntersects(_ cell: ILCell) -> Bool {
            cursor.map { $0.row == cell.row && Int($0.column) >= Int(cell.column) && Int($0.column) < Int(cell.column) + Int(cell.width) } ?? false
        }
        func value(_ input: ILCell) -> String {
            var cell = input
            return withUnsafePointer(to: &cell.text) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
            }
        }
        func compatible(_ index: Int) -> Bool {
            let cell = cells[index], width = Int(cells[index].width)
            guard width > 0, cell.row == first.row, requiresContext(initialScalar(cell)), sameStyle(first, cell),
                  !cursorIntersects(cell), index + width <= cells.count else { return false }
            for offset in 1..<width {
                let continuation = cells[index + offset]
                if continuation.width != 0 || continuation.row != cell.row || Int(continuation.column) != Int(cell.column) + offset || !sameStyle(first, continuation) { return false }
            }
            return true
        }
        guard compatible(start), maximumColumns > 0 else { return nil }
        // Keep word context across atlas-sized tiles. Only the visible tile is
        // rasterized, so long joins do not require a whole-line texture.
        var contextStart = start, contextUnits = value(first).utf16.count
        while contextStart > 0 {
            var previous = contextStart - 1
            if cells[previous].width == 0 && previous > 0 { previous -= 1 }
            let cell = cells[previous]
            guard compatible(previous), Int(cell.column) + Int(cell.width) == Int(cells[contextStart].column) else { break }
            let units = value(cell).utf16.count
            guard contextUnits + units <= maximumUTF16 else { break }
            contextUnits += units; contextStart = previous
        }
        var text = "", clusters: [Cluster] = []
        var index = contextStart, utf16Count = 0, visibleCells = 0, visibleColumns = 0
        var expectedColumn = Int(cells[contextStart].column)
        while index < cells.count && compatible(index) {
            let cell = cells[index], width = Int(cells[index].width)
            guard Int(cell.column) == expectedColumn else { break }
            let string = value(cell), length = string.utf16.count
            guard length > 0, utf16Count + length <= maximumUTF16 else { break }
            let column = Int(cell.column) - Int(first.column)
            clusters.append(Cluster(utf16Offset: utf16Count, utf16Count: length, column: column, width: width))
            text.append(string); utf16Count += length
            if index >= start && column + width <= maximumColumns {
                visibleCells += width; visibleColumns += width
            }
            expectedColumn += width; index += width
        }
        guard clusters.count > 1, visibleCells > 0 else { return nil }
        return Run(text: text, clusters: clusters, cellCount: visibleCells, columns: visibleColumns)
    }

    /// Matches the pinned Ghostty CoreText shaper's LTR terminal-grid behavior.
    /// This intentionally does not implement paragraph-level bidirectional layout.
    static func shape(text: String, clusters: [Cluster], font: CTFont, cellWidth: CGFloat) -> [Glyph] {
        guard !text.isEmpty, !clusters.isEmpty, cellWidth > 0 else { return [] }
        let count = text.utf16.count
        var mapping = [Int](repeating: -1, count: count)
        for (index, cluster) in clusters.enumerated() {
            guard cluster.utf16Offset >= 0, cluster.utf16Count > 0, cluster.utf16Offset + cluster.utf16Count <= count else { return [] }
            for unit in cluster.utf16Offset..<(cluster.utf16Offset + cluster.utf16Count) { mapping[unit] = index }
        }
        guard mapping.allSatisfy({ $0 >= 0 }) else { return [] }
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        guard let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(attributed, [kCTTypesetterOptionForcedEmbeddingLevel: 0] as CFDictionary) else { return [] }
        let line = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: 0))
        var result: [Glyph] = []
        result.reserveCapacity(CTLineGetGlyphCount(line))
        var advanceX: CGFloat = 0, anchorX: CGFloat = 0, anchorColumn = clusters[0].column, furthestColumn = clusters[0].column
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let size = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: size)
            var positions = [CGPoint](repeating: .zero, count: size)
            var advances = [CGSize](repeating: .zero, count: size)
            var indices = [CFIndex](repeating: 0, count: size)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetAdvances(run, CFRange(), &advances)
            CTRunGetStringIndices(run, CFRange(), &indices)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for index in 0..<size {
                let source = indices[index]
                guard mapping.indices.contains(source) else { continue }
                let cluster = clusters[mapping[source]]
                // A reordered mark may precede its base. Keep its CoreText
                // relative position rather than snapping it to another cell.
                if cluster.column != anchorColumn && source == cluster.utf16Offset && cluster.column > furthestColumn {
                    anchorColumn = cluster.column; anchorX = advanceX
                }
                let position = CGPoint(x: CGFloat(anchorColumn) * cellWidth + (positions[index].x - anchorX).rounded(), y: positions[index].y.rounded())
                result.append(Glyph(font: runFont, id: glyphs[index], position: position, clusterColumn: anchorColumn, stringIndex: source))
                advanceX += advances[index].width
                furthestColumn = max(furthestColumn, cluster.column)
            }
        }
        return result
    }

    static func draw(_ glyphs: [Glyph], in context: CGContext, origin: CGPoint) {
        for glyph in glyphs {
            var id = glyph.id
            var position = CGPoint(x: origin.x + glyph.position.x, y: origin.y + glyph.position.y)
            CTFontDrawGlyphs(glyph.font, &id, &position, 1, context)
        }
    }
}
