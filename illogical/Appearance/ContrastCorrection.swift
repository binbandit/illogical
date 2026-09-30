import Foundation

/// Minimum-contrast correction for text colors. Unlike Ghostty, which swaps
/// unreadable text to pure black or white, this moves the color toward black
/// or white in OKLab only as far as the ratio requires, keeping its hue.
enum ContrastCorrection {
    private typealias RGB = SIMD3<Double>

    private static func rgb(_ hex: UInt32) -> RGB {
        RGB(Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)) / 255
    }

    private static func hex(_ color: RGB) -> UInt32 {
        let channels = (color * 255).rounded(.toNearestOrAwayFromZero)
        return UInt32(channels.x) << 16 | UInt32(channels.y) << 8 | UInt32(channels.z)
    }

    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ value: Double) -> Double {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(max(0, value), 1 / 2.4) - 0.055
    }

    /// WCAG relative luminance.
    private static func luminance(_ color: RGB) -> Double {
        0.2126 * linear(color.x) + 0.7152 * linear(color.y) + 0.0722 * linear(color.z)
    }

    /// WCAG contrast ratio, from 1 to 21.
    private static func contrast(_ first: RGB, _ second: RGB) -> Double {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func oklab(_ color: RGB) -> RGB {
        let r = linear(color.x), g = linear(color.y), b = linear(color.z)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return RGB(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                   1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                   0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// OKLab to gamma-encoded sRGB, clamped to the displayable range.
    private static func rgb(oklab color: RGB) -> RGB {
        let l = pow(color.x + 0.3963377774 * color.y + 0.2158037573 * color.z, 3)
        let m = pow(color.x - 0.1055613458 * color.y - 0.0638541728 * color.z, 3)
        let s = pow(color.x - 0.0894841775 * color.y - 1.2914855480 * color.z, 3)
        let linearRGB = RGB(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        return RGB(encoded(linearRGB.x), encoded(linearRGB.y), encoded(linearRGB.z)).clamped(lowerBound: .zero, upperBound: .one)
    }

    /// Returns `foreground` unchanged when it already meets `minimumContrast`
    /// against `background`; otherwise the closest readable color. `target`
    /// (the theme foreground) gently pulls the hue toward the palette.
    static func correct(_ foreground: UInt32, background: UInt32, target: UInt32, minimumContrast: Double = 4.5) -> UInt32 {
        let text = rgb(foreground), surface = rgb(background)
        let minimum = minimumContrast.isFinite ? min(21, max(1, minimumContrast)) : 4.5
        guard contrast(text, surface) < minimum else { return foreground }
        let start = oklab(text), theme = oklab(rgb(target))
        // At least one of black and white exceeds 4.5 against any RGB color;
        // head for whichever contrasts more.
        let towardBlack = contrast(.zero, surface) >= contrast(.one, surface)
        let lightness: Double = towardBlack ? 0 : 1
        var low = 0.0, high = 1.0
        var result: UInt32 = towardBlack ? 0 : 0xffffff
        // Bisect the smallest step that reaches the minimum.
        for _ in 0..<14 {
            let amount = (low + high) / 2
            // Keep hue near the original, and taper chroma at the endpoint so
            // the search always ends at a reachable black or white.
            let chroma = 1 - pow(amount, 4)
            let candidate = rgb(oklab: RGB(start.x + (lightness - start.x) * amount,
                                           (start.y + (theme.y - start.y) * amount * 0.35) * chroma,
                                           (start.z + (theme.z - start.z) * amount * 0.35) * chroma))
            // The renderer receives 8-bit RGB, so validate those exact colors.
            let quantized = hex(candidate)
            if contrast(rgb(quantized), surface) >= minimum {
                result = quantized
                high = amount
            } else {
                low = amount
            }
        }
        return result
    }
}
