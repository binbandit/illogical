import Foundation
import CoreGraphics

enum SearchOverlayPlacement {
    static func origin(viewport: CGSize, bar: CGSize, cell: CGSize, titleHeight: CGFloat,
                       spans: [TerminalSearchSpan]) -> CGPoint {
        let padding: CGFloat = 8
        let x = max(padding, viewport.width - bar.width - 12)
        let minY = titleHeight + padding
        let maxY = max(minY, viewport.height - bar.height - padding)
        let preferred = min(maxY, titleHeight + 12)
        let matches = spans.map { span in
            CGRect(x: padding + CGFloat(span.startColumn) * cell.width,
                   y: titleHeight + padding + CGFloat(span.row) * cell.height,
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
