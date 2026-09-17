// SceneCurve.swift
// Monotone cubic (Fritsch–Carlson) sampling of a scene curve in Oklch — the
// exact math the daemon executes (scenes.rs), so what the editor draws is
// what the lights will do. Smooth, never overshooting past a keyframe, and
// evenly paced to the eye.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import Foundation

public enum SceneCurve {

    /// The interpolated point at timeline position `t` (clamped to the ends).
    /// `points` must be sorted by `t` with no duplicates (as validated and
    /// stored by the daemon). Keyframes convert to Oklch, and each of
    /// lightness, chroma and hue follows its own spline. Hue is circular and
    /// takes the short way around the wheel (see `unwrapHues`).
    public static func sample(_ points: [ScenePoint], at t: Double) -> ScenePoint {
        let xs = points.map(\.t)
        let colors = points.map { SceneColor.oklch(hue: $0.hue, saturation: $0.saturation, level: $0.level) }
        func channel(_ ys: [Double]) -> Double {
            interpolate(xs: xs, ys: ys, t: t)
        }
        let hue = channel(unwrapHues(chromaticHues(colors)))
        let color = SceneColor.Oklch(l: channel(colors.map(\.l)),
                                     c: max(0, channel(colors.map(\.c))),
                                     h: hue - floor(hue))   // wrap back into 0...1
        let hsb = SceneColor.hsb(color)
        return ScenePoint(t: t,
                          hue: hsb.hue,
                          saturation: min(1, max(0, hsb.saturation)),
                          level: min(1, max(0, hsb.level)))
    }

    /// The hue of each color, with achromatic colors (greys, black, white)
    /// taking the hue of the nearest chromatic neighbor — their own hue is
    /// noise, and a fade from white to orange should hold orange throughout
    /// rather than sweep the wheel. Mirrors the daemon's `chromatic_hues`.
    static func chromaticHues(_ colors: [SceneColor.Oklch]) -> [Double] {
        let first = colors.first { $0.c > SceneColor.achromaticChroma }?.h ?? 0
        var carried = first
        return colors.map { color in
            if color.c > SceneColor.achromaticChroma {
                carried = color.h
            }
            return carried
        }
    }

    /// Hue is a circle (0 and 1 are the same red), but the spline
    /// interpolates on a line — so unwrap the hue sequence first: shift each
    /// value by whole turns until it sits within half a turn of its
    /// predecessor. Interpolation then takes the short way around the wheel,
    /// and samples wrap back into 0...1. Mirrors the daemon's `unwrap_hues`.
    static func unwrapHues(_ hues: [Double]) -> [Double] {
        var unwrapped: [Double] = []
        unwrapped.reserveCapacity(hues.count)
        for value in hues {
            var hue = value
            if let previous = unwrapped.last {
                while hue - previous > 0.5 { hue -= 1 }
                while previous - hue > 0.5 { hue += 1 }
            }
            unwrapped.append(hue)
        }
        return unwrapped
    }

    /// One channel of Fritsch–Carlson. With two points it reduces to linear.
    static func interpolate(xs: [Double], ys: [Double], t: Double) -> Double {
        let n = xs.count
        if n == 1 || t <= xs[0] { return ys[0] }
        if t >= xs[n - 1] { return ys[n - 1] }

        // Secant slopes per interval, then tangents per point.
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            d[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i])
        }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) {
            // A tangent of 0 at local extrema keeps the curve monotone per side.
            m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2
        }
        // Fritsch–Carlson limiter: clamp tangents so no interval overshoots.
        for i in 0..<(n - 1) {
            if d[i] == 0 {
                m[i] = 0
                m[i + 1] = 0
                continue
            }
            let a: Double = m[i] / d[i]
            let b: Double = m[i + 1] / d[i]
            let s: Double = a * a + b * b
            if s > 9.0 {
                let tau: Double = 3.0 / s.squareRoot()
                m[i] = tau * a * d[i]
                m[i + 1] = tau * b * d[i]
            }
        }

        // Cubic Hermite on the containing interval.
        let i = (0..<n - 1).first { t < xs[$0 + 1] } ?? (n - 2)
        let h = xs[i + 1] - xs[i]
        let s = (t - xs[i]) / h
        let h00 = (1 + 2 * s) * (1 - s) * (1 - s)
        let h10 = s * (1 - s) * (1 - s)
        let h01 = s * s * (3 - 2 * s)
        let h11 = s * s * (s - 1)
        return h00 * ys[i] + h10 * h * m[i] + h01 * ys[i + 1] + h11 * h * m[i + 1]
    }
}
