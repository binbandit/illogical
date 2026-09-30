import CoreText
import Foundation

/// Contextual scripts need adjacent terminal cells to reach the shaper together.
/// ASCII, emoji and terminal graphics retain the per-cell fast path.
enum TerminalTextRuns {
    struct Cluster: Hashable {
        let utf16Offset: Int
        let utf16Count: Int
        /// Grid column relative to the run's first visible cell; negative for leading context.
        let column: Int
        let width: Int
    }

    struct Run: Hashable {
        let text: String
        let clusters: [Cluster]
        /// Visible cells (including wide-character spacers) that this run draws.
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

    /// Cells that may share a shaped run: every visual attribute must match.
    static func sameStyle(_ first: ILCell, _ second: ILCell) -> Bool {
        first.foreground == second.foreground && first.background == second.background
            && first.flags == second.flags && first.underlineStyle == second.underlineStyle
            && first.underlineColor == second.underlineColor && first.attributes == second.attributes
    }

    static func font(of run: CTRun) -> CTFont {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        // CoreText always attributes a run with the font that shaped it.
        return attributes[kCTFontAttributeName] as! CTFont
    }

    /// Plans the contextual run that starts at `start`, or nil when the cell
    /// draws on its own. Context before `start` shapes the visible tile but is
    /// clipped away, so long joins never need a whole-line texture.
    static func plan(_ cells: UnsafeBufferPointer<ILCell>, at start: Int, cursor: Cursor? = nil,
                     maximumColumns: Int = 64, maximumUTF16: Int = 1024) -> Run? {
        guard cells.indices.contains(start) else { return nil }
        let first = cells[start]
        guard first.width > 0, requiresContext(first.firstScalar), maximumColumns > 0 else { return nil }

        func coversCursor(_ cell: ILCell) -> Bool {
            guard let cursor, cursor.row == cell.row else { return false }
            return Int(cursor.column) >= Int(cell.column) && Int(cursor.column) < Int(cell.column) + Int(cell.width)
        }
        func joins(_ index: Int) -> Bool {
            let cell = cells[index], width = Int(cell.width)
            guard width > 0, cell.row == first.row, requiresContext(cell.firstScalar), sameStyle(first, cell),
                  !coversCursor(cell), index + width <= cells.count else { return false }
            // Wide characters carry spacer cells that must share the style.
            for offset in 1..<width {
                let spacer = cells[index + offset]
                guard spacer.width == 0, spacer.row == cell.row, Int(spacer.column) == Int(cell.column) + offset,
                      sameStyle(first, spacer) else { return false }
            }
            return true
        }
        guard joins(start) else { return nil }

        var contextStart = start, contextUnits = first.string.utf16.count
        while contextStart > 0 {
            var previous = contextStart - 1
            if cells[previous].width == 0 && previous > 0 { previous -= 1 }
            let cell = cells[previous]
            guard joins(previous), Int(cell.column) + Int(cell.width) == Int(cells[contextStart].column) else { break }
            let units = cell.string.utf16.count
            guard contextUnits + units <= maximumUTF16 else { break }
            contextUnits += units
            contextStart = previous
        }

        var text = "", clusters: [Cluster] = []
        var index = contextStart, utf16Count = 0, visibleColumns = 0
        var expectedColumn = Int(cells[contextStart].column)
        while index < cells.count && joins(index) {
            let cell = cells[index], width = Int(cell.width)
            guard Int(cell.column) == expectedColumn else { break }
            let string = cell.string, length = string.utf16.count
            guard length > 0, utf16Count + length <= maximumUTF16 else { break }
            let column = Int(cell.column) - Int(first.column)
            clusters.append(Cluster(utf16Offset: utf16Count, utf16Count: length, column: column, width: width))
            text.append(string)
            utf16Count += length
            if index >= start && column + width <= maximumColumns { visibleColumns += width }
            expectedColumn += width
            index += width
        }
        guard clusters.count > 1, visibleColumns > 0 else { return nil }
        return Run(text: text, clusters: clusters, cellCount: visibleColumns, columns: visibleColumns)
    }

    /// Matches the pinned Ghostty CoreText shaper's LTR terminal-grid behavior.
    /// This intentionally does not implement paragraph-level bidirectional layout.
    static func shape(text: String, clusters: [Cluster], font: CTFont, cellWidth: CGFloat) -> [Glyph] {
        guard !text.isEmpty, !clusters.isEmpty, cellWidth > 0 else { return [] }
        let count = text.utf16.count
        var clusterOfUnit = [Int](repeating: -1, count: count)
        for (index, cluster) in clusters.enumerated() {
            guard cluster.utf16Offset >= 0, cluster.utf16Count > 0, cluster.utf16Offset + cluster.utf16Count <= count else { return [] }
            for unit in cluster.utf16Offset..<(cluster.utf16Offset + cluster.utf16Count) { clusterOfUnit[unit] = index }
        }
        guard clusterOfUnit.allSatisfy({ $0 >= 0 }) else { return [] }
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        guard let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(
            attributed, [kCTTypesetterOptionForcedEmbeddingLevel: 0] as CFDictionary) else { return [] }
        let line = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: 0))

        var result: [Glyph] = []
        result.reserveCapacity(CTLineGetGlyphCount(line))
        var advanceX: CGFloat = 0, anchorX: CGFloat = 0
        var anchorColumn = clusters[0].column, furthestColumn = clusters[0].column
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let size = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: size)
            var positions = [CGPoint](repeating: .zero, count: size)
            var advances = [CGSize](repeating: .zero, count: size)
            var indices = [CFIndex](repeating: 0, count: size)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetAdvances(run, CFRange(), &advances)
            CTRunGetStringIndices(run, CFRange(), &indices)
            let runFont = Self.font(of: run)
            for index in 0..<size {
                let source = indices[index]
                guard clusterOfUnit.indices.contains(source) else { continue }
                let cluster = clusters[clusterOfUnit[source]]
                // A reordered mark may precede its base. Keep its CoreText
                // relative position rather than snapping it to another cell.
                if cluster.column != anchorColumn && source == cluster.utf16Offset && cluster.column > furthestColumn {
                    anchorColumn = cluster.column
                    anchorX = advanceX
                }
                let position = CGPoint(x: CGFloat(anchorColumn) * cellWidth + (positions[index].x - anchorX).rounded(),
                                       y: positions[index].y.rounded())
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
