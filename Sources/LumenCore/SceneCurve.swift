// SceneCurve.swift
// Monotone cubic (Fritsch–Carlson) sampling of a scene curve — the exact
// math the daemon executes (scenes.rs), so what the editor draws is what the
// lights will do. Smooth, but never overshooting past a keyframe.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import Foundation

public enum SceneCurve {

    /// The interpolated point at timeline position `t` (clamped to the ends).
    /// `points` must be sorted by `t` with no duplicates (as validated and
    /// stored by the daemon). Hue is circular and takes the short way around
    /// the wheel (see `unwrapHues`).
    public static func sample(_ points: [ScenePoint], at t: Double) -> ScenePoint {
        let xs = points.map(\.t)
        func channel(_ ys: [Double]) -> Double {
            min(1, max(0, interpolate(xs: xs, ys: ys, t: t)))
        }
        let hue = interpolate(xs: xs, ys: unwrapHues(points), t: t)
        return ScenePoint(t: t,
                          hue: hue - floor(hue),   // wrap back into 0...1
                          saturation: channel(points.map(\.saturation)),
                          level: channel(points.map(\.level)))
    }

    /// Hue is a circle (0 and 1 are the same red), but the spline
    /// interpolates on a line — so unwrap the hue sequence first: shift each
    /// value by whole turns until it sits within half a turn of its
    /// predecessor. Interpolation then takes the short way around the wheel,
    /// and samples wrap back into 0...1. Mirrors the daemon's `unwrap_hues`.
    static func unwrapHues(_ points: [ScenePoint]) -> [Double] {
        var hues: [Double] = []
        hues.reserveCapacity(points.count)
        for point in points {
            var hue = point.hue
            if let previous = hues.last {
                while hue - previous > 0.5 { hue -= 1 }
                while previous - hue > 0.5 { hue += 1 }
            }
            hues.append(hue)
        }
        return hues
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
