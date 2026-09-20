import Foundation

enum ContrastCorrection {
    private static func rgb(_ hex: UInt32) -> SIMD3<Double> {
        SIMD3(Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255)
    }
    private static func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
    private static func encoded(_ value: Double) -> Double { value <= 0.0031308 ? value * 12.92 : 1.055 * pow(max(0, value), 1 / 2.4) - 0.055 }
    private static func luminance(_ c: SIMD3<Double>) -> Double { 0.2126 * linear(c.x) + 0.7152 * linear(c.y) + 0.0722 * linear(c.z) }
    private static func contrast(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let x=luminance(a), y=luminance(b);return (max(x,y)+0.05)/(min(x,y)+0.05)
    }
    private static func lab(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let r=linear(c.x),g=linear(c.y),b=linear(c.z)
        let l=cbrt(0.4122214708*r+0.5363325363*g+0.0514459929*b)
        let m=cbrt(0.2119034982*r+0.6806995451*g+0.1073969566*b)
        let s=cbrt(0.0883024619*r+0.2817188376*g+0.6299787005*b)
        return SIMD3(0.2104542553*l+0.793617785*m-0.0040720468*s,1.9779984951*l-2.428592205*m+0.4505937099*s,0.0259040371*l+0.7827717662*m-0.808675766*s)
    }
    private static func fromLab(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l=pow(c.x+0.3963377774*c.y+0.2158037573*c.z,3)
        let m=pow(c.x-0.1055613458*c.y-0.0638541728*c.z,3)
        let s=pow(c.x-0.0894841775*c.y-1.291485548*c.z,3)
        return SIMD3(min(1,max(0,encoded(4.0767416621*l-3.3077115913*m+0.2309699292*s))),min(1,max(0,encoded(-1.2684380046*l+2.6097574011*m-0.3413193965*s))),min(1,max(0,encoded(-0.0041960863*l-0.7034186147*m+1.707614701*s))))
    }
    static func correct(_ foreground: UInt32, background: UInt32, target: UInt32, minimumContrast: Double = 4.5) -> UInt32 {
        let fg=rgb(foreground),bg=rgb(background)
        let minimum = minimumContrast.isFinite ? min(21, max(1, minimumContrast)) : 4.5
        guard contrast(fg,bg)<minimum else{return foreground}
        let start=lab(fg),theme=lab(rgb(target))
        // At least one of black and white exceeds 4.5 against any RGB color.
        // A fixed luminance cutoff of 0.4 chose unreachable white targets for
        // mid-gray backgrounds and could leave the original text unchanged.
        let destination:Double=contrast(.zero,bg)>=contrast(SIMD3(repeating:1),bg) ? 0 : 1
        var low=0.0,high=1.0
        var result:UInt32=destination==0 ? 0 : 0xffffff
        for _ in 0..<14 {
            let amount=(low+high)/2
            // Preserve hue near the original; taper chroma at the endpoint so
            // the search always terminates at a reachable black or white.
            let chroma=1-pow(amount,4)
            let candidate=fromLab(SIMD3(start.x+(destination-start.x)*amount,(start.y+(theme.y-start.y)*amount*0.35)*chroma,(start.z+(theme.z-start.z)*amount*0.35)*chroma))
            let encoded=UInt32((candidate.x*255).rounded())<<16 | UInt32((candidate.y*255).rounded())<<8 | UInt32((candidate.z*255).rounded())
            // The renderer receives 8-bit RGB, so validate those exact colors.
            if contrast(rgb(encoded),bg)>=minimum{result=encoded;high=amount}else{low=amount}
        }
        return result
    }
}
