import Foundation
import CoreGraphics

enum TerminalCellGeometry {
    /// Fractions of the terminal cell, in top-left coordinates. Shared edges stay exact.
    static let blocks: [[CGRect]] = (0x2580...0x259f).map { scalar in
        switch scalar {
        case 0x2580: return [CGRect(x:0,y:0,width:1,height:0.5)]
        case 0x2581...0x2588:
            let height = Double(scalar - 0x2580) / 8
            return [CGRect(x:0,y:1-height,width:1,height:height)]
        case 0x2589...0x258f: return [CGRect(x:0,y:0,width:Double(0x2590-scalar)/8,height:1)]
        case 0x2590: return [CGRect(x:0.5,y:0,width:0.5,height:1)]
        case 0x2594: return [CGRect(x:0,y:0,width:1,height:0.125)]
        case 0x2595: return [CGRect(x:0.875,y:0,width:0.125,height:1)]
        case 0x2596...0x259f:
            let masks = [4,8,1,13,9,7,11,2,6,14]
            let mask = masks[scalar-0x2596]
            return (0..<4).compactMap { index in
                mask & (1 << index) != 0 ? CGRect(x:Double(index%2)/2,y:Double(index/2)/2,width:0.5,height:0.5) : nil
            }
        default: return []
        }
    }
}
