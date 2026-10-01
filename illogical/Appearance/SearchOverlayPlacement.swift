import Foundation
import CoreGraphics

/// Where a pane's search bar goes: 8 pt from the pane's right edge and 6 pt
/// below its top, unless that would cover the active match.
enum SearchOverlayPlacement {
    /// The terminal's grid inset, where match rectangles start.
    private static let gridInset: CGFloat = 8
    private static let trailingInset: CGFloat = 8
    private static let topInset: CGFloat = 6

    static func origin(viewport: CGSize, bar: CGSize, cell: CGSize, titleHeight: CGFloat,
                       spans: [TerminalSearchSpan]) -> CGPoint {
        let x = max(gridInset, viewport.width - bar.width - trailingInset)
        let minY = titleHeight + topInset
        let maxY = max(minY, viewport.height - bar.height - gridInset)
        let preferred = min(maxY, minY)
        let matches = spans.map { span in
            CGRect(x: gridInset + CGFloat(span.startColumn) * cell.width,
                   y: titleHeight + gridInset + CGFloat(span.row) * cell.height,
                   width: CGFloat(span.endColumn - span.startColumn + 1) * cell.width, height: cell.height)
        }.filter { $0.minX < x + bar.width && $0.maxX > x }
        func overlaps(_ y: CGFloat) -> Bool {
            let rect = CGRect(origin: CGPoint(x: x, y: y), size: bar).insetBy(dx: -2, dy: -2)
            return matches.contains { rect.intersects($0) }
        }
        guard overlaps(preferred) else { return CGPoint(x: x, y: preferred) }
        var candidates: [CGFloat] = []
        for match in matches {
            let below = match.maxY + 3
            let above = match.minY - bar.height - 3
            if below >= minY && below <= maxY { candidates.append(below) }
            if above >= minY && above <= maxY { candidates.append(above) }
        }
        candidates.sort { abs($0 - preferred) < abs($1 - preferred) }
        return CGPoint(x: x, y: candidates.first(where: { !overlaps($0) }) ?? maxY)
    }
}
