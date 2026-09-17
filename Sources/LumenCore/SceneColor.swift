// SceneColor.swift
// Conversions between a light's hue/saturation/level and Oklch, the
// perceptual color space scene curves interpolate in — the exact math the
// daemon executes (color.rs). Hue/saturation/level is treated as HSV over
// sRGB: an approximation of the bridge's own scale, but one in which even
// steps look even.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import Foundation

public enum SceneColor {

    /// A color in Oklch: lightness, chroma, and hue in turns (0...1).
    public struct Oklch: Equatable {
        public var l: Double
        public var c: Double
        public var h: Double

        public init(l: Double, c: Double, h: Double) {
            self.l = l
            self.c = c
            self.h = h
        }
    }

    /// Chroma at or below this counts as achromatic: the hue carries no
    /// information. Round-trips of greys land around 1e-8.
    public static let achromaticChroma = 1e-4

    /// Convert a light's hue/saturation/level (each 0...1) to Oklch.
    public static func oklch(hue: Double, saturation: Double, level: Double) -> Oklch {
        let rgb = hsbToRGB(hue: hue, saturation: saturation, level: level).map(srgbToLinear)
        return oklabToOklch(linearRGBToOklab(rgb))
    }

    /// Convert an Oklch color back to hue/saturation/level, clipping colors
    /// outside the sRGB gamut to its edge.
    public static func hsb(_ color: Oklch) -> (hue: Double, saturation: Double, level: Double) {
        let rgb = oklabToLinearRGB(oklchToOklab(color)).map { linearToSRGB(min(1, max(0, $0))) }
        return rgbToHSB(rgb)
    }

    /// HSV to sRGB, hue in turns.
    static func hsbToRGB(hue: Double, saturation: Double, level: Double) -> [Double] {
        let sector = (hue - floor(hue)) * 6
        let index = Int(floor(sector)) % 6
        let fraction = sector - floor(sector)
        let low = level * (1 - saturation)
        let falling = level * (1 - saturation * fraction)
        let rising = level * (1 - saturation * (1 - fraction))
        switch index {
        case 0: return [level, rising, low]
        case 1: return [falling, level, low]
        case 2: return [low, level, rising]
        case 3: return [low, falling, level]
        case 4: return [rising, low, level]
        default: return [level, low, falling]
        }
    }

    /// sRGB to HSV, hue in turns. A grey has hue 0.
    static func rgbToHSB(_ rgb: [Double]) -> (hue: Double, saturation: Double, level: Double) {
        let (r, g, b) = (rgb[0], rgb[1], rgb[2])
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let delta = maximum - minimum
        if maximum <= 0 || delta <= 0 {
            return (0, 0, maximum)
        }
        let sector: Double
        if maximum == r {
            sector = (g - b) / delta
        } else if maximum == g {
            sector = 2 + (b - r) / delta
        } else {
            sector = 4 + (r - g) / delta
        }
        let hue = sector / 6
        return (hue - floor(hue), delta / maximum, maximum)
    }

    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func linearToSRGB(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// Linear sRGB to Oklab (Björn Ottosson's published matrices).
    static func linearRGBToOklab(_ rgb: [Double]) -> [Double] {
        let (r, g, b) = (rgb[0], rgb[1], rgb[2])
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return [
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
        ]
    }

    /// Oklab to linear sRGB; components may fall outside 0...1 for colors
    /// outside the gamut.
    static func oklabToLinearRGB(_ lab: [Double]) -> [Double] {
        let (lightness, a, b) = (lab[0], lab[1], lab[2])
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        return [
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
        ]
    }

    static func oklabToOklch(_ lab: [Double]) -> Oklch {
        let (l, a, b) = (lab[0], lab[1], lab[2])
        let turns = atan2(b, a) / (2 * Double.pi)
        return Oklch(l: l, c: hypot(a, b), h: turns - floor(turns))
    }

    static func oklchToOklab(_ color: Oklch) -> [Double] {
        let angle = color.h * 2 * Double.pi
        return [color.l, color.c * cos(angle), color.c * sin(angle)]
    }
}
