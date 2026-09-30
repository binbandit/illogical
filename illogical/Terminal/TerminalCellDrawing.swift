import CoreGraphics

/// Box drawing, Braille and Powerline separators drawn from cell geometry,
/// independent of the text font, so they join across cells like Ghostty's sprites.
enum TerminalCellDrawing {
    /// Glyphs that are terminal graphics rather than text: they keep their
    /// requested colors instead of receiving minimum-contrast correction.
    static func isGraphicsElement(_ scalar: UInt32) -> Bool {
        (0x2500...0x259f).contains(scalar) || (0xe0b0...0xe0d7).contains(scalar)
            || (0x1fb00...0x1fbff).contains(scalar) || (0x1cc00...0x1cebf).contains(scalar)
    }

    static func supports(_ scalar: UInt32) -> Bool {
        boxDrawing.contains(scalar) || braille.contains(scalar) || powerline.contains(scalar)
    }

    private static let boxDrawing: ClosedRange<UInt32> = 0x2500...0x257f
    private static let braille: ClosedRange<UInt32> = 0x2800...0x28ff
    private static let powerline: ClosedRange<UInt32> = 0xe0b0...0xe0b7

    /// Draws white coverage into `context`, whose origin is the cell's top-left
    /// corner with y pointing down. `thickness` is a light line in pixels.
    static func draw(_ scalar: UInt32, in context: CGContext, size: CGSize, thickness: CGFloat) {
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        let lines = Lines(size: size, light: max(1, thickness.rounded()))
        if braille.contains(scalar) { drawBraille(scalar - braille.lowerBound, in: context, size: size) }
        else if powerline.contains(scalar) { drawPowerline(scalar, in: context, size: size, lineWidth: lines.light) }
        else if (0x256d...0x2570).contains(scalar) { lines.drawArc(scalar, in: context) }
        else if (0x2571...0x2573).contains(scalar) { lines.drawDiagonal(scalar, in: context) }
        else if (0x2504...0x250b).contains(scalar) || (0x254c...0x254f).contains(scalar) { lines.drawDashed(scalar, in: context) }
        else if boxDrawing.contains(scalar) { lines.drawArms(arms[Int(scalar - boxDrawing.lowerBound)], in: context) }
    }

    private static func drawBraille(_ bits: UInt32, in context: CGContext, size: CGSize) {
        // Dot numbering: 1-3 and 7 down the left column, 4-6 and 8 down the right.
        let dots: [(column: Int, row: Int)] = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3)]
        let diameter = max(1, min(size.width / 4, size.height / 7))
        for (bit, dot) in dots.enumerated() where bits & (1 << bit) != 0 {
            let x = size.width * (dot.column == 0 ? 0.25 : 0.75), y = size.height * (CGFloat(dot.row) + 0.5) / 4
            context.fillEllipse(in: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
        }
    }

    private static func drawPowerline(_ scalar: UInt32, in context: CGContext, size: CGSize, lineWidth: CGFloat) {
        let pointsLeft = [0xe0b2, 0xe0b3, 0xe0b6, 0xe0b7].contains(scalar)
        let outline = scalar % 2 == 1
        let rounded = scalar >= 0xe0b4
        let width = size.width, height = size.height
        if pointsLeft { context.translateBy(x: width, y: 0); context.scaleBy(x: -1, y: 1) }
        context.move(to: .zero)
        if rounded {
            context.addCurve(to: CGPoint(x: 0, y: height), control1: CGPoint(x: width * 4 / 3, y: 0), control2: CGPoint(x: width * 4 / 3, y: height))
        } else {
            context.addLine(to: CGPoint(x: width, y: height / 2))
            context.addLine(to: CGPoint(x: 0, y: height))
        }
        if outline {
            context.setLineWidth(lineWidth)
            context.strokePath()
        } else {
            context.closePath()
            context.fillPath()
        }
    }

    /// Stroke weights for each arm: two bits per direction (up, right, down,
    /// left from the low bits); 0 absent, 1 light, 2 heavy, 3 double.
    private static let arms: [UInt8] = [
        68, 136, 17, 34, 0, 0, 0, 0, 0, 0, 0, 0, 20, 24, 36, 40,
        80, 144, 96, 160, 5, 9, 6, 10, 65, 129, 66, 130, 21, 25, 22, 37,
        38, 26, 41, 42, 81, 145, 82, 97, 98, 146, 161, 162, 84, 148, 88, 152,
        100, 164, 104, 168, 69, 133, 73, 137, 70, 134, 74, 138, 85, 149, 89, 153,
        86, 101, 102, 150, 90, 165, 105, 154, 169, 166, 106, 170, 0, 0, 0, 0,
        204, 51, 28, 52, 60, 208, 112, 240, 13, 7, 15, 193, 67, 195, 29, 55,
        63, 209, 115, 243, 220, 116, 252, 205, 71, 207, 221, 119, 255, 0, 0, 0,
        0, 0, 0, 0, 64, 1, 4, 16, 128, 2, 8, 32, 72, 33, 132, 18
    ]

    private enum Weight: UInt8 { case none, light, heavy, double }
    private enum Direction: Int, CaseIterable {
        case up, right, down, left
        var isVertical: Bool { self == .up || self == .down }
        /// -1 toward the top or left edge, 1 toward the bottom or right edge.
        var outward: CGFloat { self == .up || self == .left ? -1 : 1 }
    }

    /// Pixel-aligned line geometry shared by every box-drawing shape, so that
    /// straight arms, arcs and dashes in neighbouring cells meet exactly.
    private struct Lines {
        let width: CGFloat, height: CGFloat
        let light: CGFloat, heavy: CGFloat
        let centerX: CGFloat, centerY: CGFloat

        init(size: CGSize, light: CGFloat) {
            width = size.width; height = size.height
            self.light = light; heavy = light * 2
            centerX = floor(width / 2); centerY = floor(height / 2)
        }

        /// The leading edge of a line of `thickness` centered near `center`.
        func edge(_ center: CGFloat, _ thickness: CGFloat) -> CGFloat { floor(center - thickness / 2) }

        func drawArms(_ encoded: UInt8, in context: CGContext) {
            context.setShouldAntialias(false)
            let weights = Direction.allCases.map { Weight(rawValue: (encoded >> ($0.rawValue * 2)) & 3) ?? .none }
            for direction in Direction.allCases {
                let weight = weights[direction.rawValue]
                guard weight != .none else { continue }
                let thickness = weight == .heavy ? heavy : light
                // Perpendicular arms decide where a double line's strokes stop.
                let before = weights[direction.isVertical ? Direction.left.rawValue : Direction.up.rawValue]
                let after = weights[direction.isVertical ? Direction.right.rawValue : Direction.down.rawValue]
                for offset in weight == .double ? [-light, light] : [0] {
                    let endpoint: CGFloat
                    if weight == .double {
                        if before == .double && after == .double { endpoint = direction.outward * light }
                        else if after == .double { endpoint = direction.outward * offset }
                        else if before == .double { endpoint = -direction.outward * offset }
                        else { endpoint = 0 }
                    } else {
                        endpoint = before == .double || after == .double ? -direction.outward * light : 0
                    }
                    let begin = edge((direction.isVertical ? centerY : centerX) + endpoint, thickness)
                    let end = begin + thickness
                    let x = edge(centerX + offset, thickness), y = edge(centerY + offset, thickness)
                    switch direction {
                    case .up: context.fill(CGRect(x: x, y: 0, width: thickness, height: end))
                    case .right: context.fill(CGRect(x: begin, y: y, width: width - begin, height: thickness))
                    case .down: context.fill(CGRect(x: x, y: begin, width: thickness, height: height - begin))
                    case .left: context.fill(CGRect(x: 0, y: y, width: end, height: thickness))
                    }
                }
            }
        }

        /// ╭╮╯╰, stroked along the same centerline as the straight light arms.
        func drawArc(_ scalar: UInt32, in context: CGContext) {
            let x = edge(centerX, light) + light / 2, y = edge(centerY, light) + light / 2
            let corner = CGPoint(x: x, y: y)
            let (start, end): (CGPoint, CGPoint) = switch scalar {
            case 0x256d: (CGPoint(x: width, y: y), CGPoint(x: x, y: height))
            case 0x256e: (CGPoint(x: 0, y: y), CGPoint(x: x, y: height))
            case 0x256f: (CGPoint(x: 0, y: y), CGPoint(x: x, y: 0))
            default: (CGPoint(x: width, y: y), CGPoint(x: x, y: 0))
            }
            context.setLineWidth(light)
            context.move(to: start)
            context.addArc(tangent1End: corner, tangent2End: end, radius: min(width, height) / 2)
            context.addLine(to: end)
            context.strokePath()
        }

        func drawDiagonal(_ scalar: UInt32, in context: CGContext) {
            context.setLineWidth(light)
            if scalar != 0x2572 { context.move(to: CGPoint(x: 0, y: height)); context.addLine(to: CGPoint(x: width, y: 0)) }
            if scalar != 0x2571 { context.move(to: .zero); context.addLine(to: CGPoint(x: width, y: height)) }
            context.strokePath()
        }

        /// ┄┅┆┇┈┉┊┋╌╍╎╏: odd scalars are heavy; bit 1 selects vertical.
        func drawDashed(_ scalar: UInt32, in context: CGContext) {
            context.setShouldAntialias(false)
            let vertical = scalar & 2 != 0
            let count = scalar >= 0x254c ? 2 : scalar >= 0x2508 ? 4 : 3
            let thickness = scalar & 1 == 1 ? heavy : light
            let length = (vertical ? height : width) / CGFloat(count)
            for index in 0..<count {
                let start = CGFloat(index) * length
                context.fill(vertical
                    ? CGRect(x: edge(centerX, thickness), y: start, width: thickness, height: length * 0.65)
                    : CGRect(x: start, y: edge(centerY, thickness), width: length * 0.65, height: thickness))
            }
        }
    }
}
