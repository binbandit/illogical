import CoreGraphics

/// Terminal graphics use cell geometry, independent of a text font's line spacing.
enum TerminalCellDrawing {
    static func isGraphicsElement(_ scalar: UInt32) -> Bool {
        (0x2500...0x259f).contains(scalar) || (0xe0b0...0xe0d7).contains(scalar)
            || (0x1fb00...0x1fbff).contains(scalar) || (0x1cc00...0x1cebf).contains(scalar)
    }

    static func supports(_ scalar: UInt32) -> Bool {
        (0x2500...0x257f).contains(scalar) || (0x2800...0x28ff).contains(scalar) || (0xe0b0...0xe0b7).contains(scalar)
    }

    // Unicode box drawing: two bits each for up, right, down, left;
    // 0 absent, 1 light, 2 heavy, 3 double.
    private static let arms: [UInt8] = [
        68,136,17,34,0,0,0,0,0,0,0,0,20,24,36,40,
        80,144,96,160,5,9,6,10,65,129,66,130,21,25,22,37,
        38,26,41,42,81,145,82,97,98,146,161,162,84,148,88,152,
        100,164,104,168,69,133,73,137,70,134,74,138,85,149,89,153,
        86,101,102,150,90,165,105,154,169,166,106,170,0,0,0,0,
        204,51,28,52,60,208,112,240,13,7,15,193,67,195,29,55,
        63,209,115,243,220,116,252,205,71,207,221,119,255,0,0,0,
        0,0,0,0,64,1,4,16,128,2,8,32,72,33,132,18
    ]

    static func draw(_ scalar: UInt32, in context: CGContext, size: CGSize) {
        let w = size.width, h = size.height
        let light = max(1, round(w / 8)), heavy = light * 2
        let cx = floor(w / 2), cy = floor(h / 2)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(light)
        if (0x2800...0x28ff).contains(scalar) {
            let bits = scalar - 0x2800
            let diameter = max(1, min(w / 4, h / 7))
            for (bit, position) in [(0,(0,0)),(1,(0,1)),(2,(0,2)),(3,(1,0)),(4,(1,1)),(5,(1,2)),(6,(0,3)),(7,(1,3))] where bits & (1 << bit) != 0 {
                context.fillEllipse(in: CGRect(x: w * (position.0 == 0 ? 0.25 : 0.75) - diameter / 2,
                                               y: h * (CGFloat(position.1) + 0.5) / 4 - diameter / 2, width: diameter, height: diameter))
            }
            return
        }
        if (0xe0b0...0xe0b7).contains(scalar) {
            let reverse = scalar == 0xe0b2 || scalar == 0xe0b3 || scalar == 0xe0b6 || scalar == 0xe0b7
            let outline = scalar % 2 == 1
            if reverse { context.translateBy(x: w, y: 0); context.scaleBy(x: -1, y: 1) }
            context.move(to: CGPoint(x: 0, y: 0))
            if scalar >= 0xe0b4 {
                context.addCurve(to: CGPoint(x: 0, y: h), control1: CGPoint(x: w * 4 / 3, y: 0), control2: CGPoint(x: w * 4 / 3, y: h))
            } else {
                context.addLine(to: CGPoint(x: w, y: h / 2)); context.addLine(to: CGPoint(x: 0, y: h))
            }
            if outline { context.strokePath() } else { context.closePath(); context.fillPath() }
            return
        }
        if (0x256d...0x2570).contains(scalar) {
            let radius = min(w / 2, h / 2)
            let paths: [(CGPoint,CGPoint,CGPoint)] = [
                (CGPoint(x:w,y:cy),CGPoint(x:cx,y:cy),CGPoint(x:cx,y:h)),
                (CGPoint(x:0,y:cy),CGPoint(x:cx,y:cy),CGPoint(x:cx,y:h)),
                (CGPoint(x:0,y:cy),CGPoint(x:cx,y:cy),CGPoint(x:cx,y:0)),
                (CGPoint(x:w,y:cy),CGPoint(x:cx,y:cy),CGPoint(x:cx,y:0))
            ]
            let path = paths[Int(scalar - 0x256d)]
            context.move(to:path.0);context.addArc(tangent1End:path.1,tangent2End:path.2,radius:radius);context.addLine(to:path.2);context.strokePath()
            return
        }
        if (0x2571...0x2573).contains(scalar) {
            if scalar != 0x2572 { context.move(to:CGPoint(x:0,y:h));context.addLine(to:CGPoint(x:w,y:0)) }
            if scalar != 0x2571 { context.move(to:.zero);context.addLine(to:CGPoint(x:w,y:h)) }
            context.strokePath();return
        }
        if (0x2504...0x250b).contains(scalar) || (0x254c...0x254f).contains(scalar) {
            let vertical = (scalar & 2) != 0
            let count = scalar >= 0x254c ? 2 : (scalar >= 0x2508 ? 4 : 3)
            let length = (vertical ? h : w) / CGFloat(count)
            let thickness = scalar & 1 == 1 ? heavy : light
            context.setShouldAntialias(false)
            for index in 0..<count {
                let offset = CGFloat(index) * length
                context.fill(vertical ? CGRect(x:cx-thickness/2,y:offset,width:thickness,height:length*0.65)
                             : CGRect(x:offset,y:cy-thickness/2,width:length*0.65,height:thickness))
            }
            return
        }
        context.setShouldAntialias(false)
        let encoded = arms[Int(scalar - 0x2500)]
        let styles = (0..<4).map { (encoded >> ($0 * 2)) & 3 }
        for direction in 0..<4 {
            let style = styles[direction]
            guard style != 0 else { continue }
            let thickness = style == 2 ? heavy : light
            let offsets: [CGFloat] = style == 3 ? [-light,light] : [0]
            for offset in offsets {
                let x = floor(cx + offset - thickness/2), y = floor(cy + offset - thickness/2)
                let vertical = direction % 2 == 0
                let negativeSide = styles[vertical ? 3 : 0], positiveSide = styles[vertical ? 1 : 2]
                let outward: CGFloat = direction == 0 || direction == 3 ? -1 : 1
                let endpoint: CGFloat
                if style == 3 {
                    if negativeSide == 3 && positiveSide == 3 { endpoint = outward * light }
                    else if positiveSide == 3 { endpoint = outward * offset }
                    else if negativeSide == 3 { endpoint = -outward * offset }
                    else { endpoint = 0 }
                } else { endpoint = (negativeSide == 3 || positiveSide == 3) ? -outward * light : 0 }
                let begin = floor((vertical ? cy : cx) + endpoint - thickness / 2)
                let end = begin + thickness
                switch direction {
                case 0: context.fill(CGRect(x:x,y:0,width:thickness,height:end))
                case 1: context.fill(CGRect(x:begin,y:y,width:w-begin,height:thickness))
                case 2: context.fill(CGRect(x:x,y:begin,width:thickness,height:h-begin))
                default: context.fill(CGRect(x:0,y:y,width:end,height:thickness))
                }
            }
        }
    }
}
