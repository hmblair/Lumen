//! Conversions between a light's hue/saturation/level and Oklch, the
//! perceptual color space scenes interpolate in. Hue/saturation/level is
//! treated as HSV over sRGB: an approximation of the bridge's own scale,
//! but one in which even steps look even.
//!
//! Author: Hamish M. Blair <hmblair@stanford.edu>

/// A color in Oklch: lightness, chroma, and hue in turns (0...1).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Oklch {
    pub l: f64,
    pub c: f64,
    pub h: f64,
}

/// Chroma at or below this counts as achromatic: the hue carries no
/// information. Round-trips of greys land around 1e-8.
pub const ACHROMATIC_CHROMA: f64 = 1e-4;

/// Convert a light's hue/saturation/level (each 0...1) to Oklch.
pub fn hsb_to_oklch(hue: f64, saturation: f64, level: f64) -> Oklch {
    let rgb = hsb_to_rgb(hue, saturation, level).map(srgb_to_linear);
    oklab_to_oklch(linear_rgb_to_oklab(rgb))
}

/// Convert an Oklch color back to hue/saturation/level, clipping colors
/// outside the sRGB gamut to its edge.
pub fn oklch_to_hsb(color: Oklch) -> (f64, f64, f64) {
    let rgb = oklab_to_linear_rgb(oklch_to_oklab(color)).map(|c| linear_to_srgb(c.clamp(0.0, 1.0)));
    rgb_to_hsb(rgb)
}

/// HSV to sRGB, hue in turns.
fn hsb_to_rgb(hue: f64, saturation: f64, level: f64) -> [f64; 3] {
    let sector = hue.rem_euclid(1.0) * 6.0;
    let index = sector.floor() as u32 % 6;
    let fraction = sector - sector.floor();
    let low = level * (1.0 - saturation);
    let falling = level * (1.0 - saturation * fraction);
    let rising = level * (1.0 - saturation * (1.0 - fraction));
    match index {
        0 => [level, rising, low],
        1 => [falling, level, low],
        2 => [low, level, rising],
        3 => [low, falling, level],
        4 => [rising, low, level],
        _ => [level, low, falling],
    }
}

/// sRGB to HSV, hue in turns. A grey has hue 0.
fn rgb_to_hsb([r, g, b]: [f64; 3]) -> (f64, f64, f64) {
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let delta = max - min;
    if max <= 0.0 || delta <= 0.0 {
        return (0.0, 0.0, max);
    }
    let sector = if max == r {
        (g - b) / delta
    } else if max == g {
        2.0 + (b - r) / delta
    } else {
        4.0 + (r - g) / delta
    };
    ((sector / 6.0).rem_euclid(1.0), delta / max, max)
}

fn srgb_to_linear(c: f64) -> f64 {
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

fn linear_to_srgb(c: f64) -> f64 {
    if c <= 0.0031308 {
        c * 12.92
    } else {
        1.055 * c.powf(1.0 / 2.4) - 0.055
    }
}

/// Linear sRGB to Oklab (Björn Ottosson's published matrices).
fn linear_rgb_to_oklab([r, g, b]: [f64; 3]) -> [f64; 3] {
    let l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b).cbrt();
    let m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b).cbrt();
    let s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b).cbrt();
    [
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    ]
}

/// Oklab to linear sRGB; components may fall outside 0...1 for colors
/// outside the gamut.
fn oklab_to_linear_rgb([lightness, a, b]: [f64; 3]) -> [f64; 3] {
    let l = (lightness + 0.3963377774 * a + 0.2158037573 * b).powi(3);
    let m = (lightness - 0.1055613458 * a - 0.0638541728 * b).powi(3);
    let s = (lightness - 0.0894841775 * a - 1.2914855480 * b).powi(3);
    [
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    ]
}

fn oklab_to_oklch([l, a, b]: [f64; 3]) -> Oklch {
    let h = (b.atan2(a) / std::f64::consts::TAU).rem_euclid(1.0);
    Oklch { l, c: a.hypot(b), h }
}

fn oklch_to_oklab(color: Oklch) -> [f64; 3] {
    let angle = color.h * std::f64::consts::TAU;
    [color.l, color.c * angle.cos(), color.c * angle.sin()]
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The published Oklab matrices are rounded to ten digits, so a round
    /// trip lands about 1e-8 off.
    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-6
    }

    #[test]
    fn hsb_round_trips_through_oklch() {
        for (hue, saturation, level) in [
            (0.0, 1.0, 1.0),
            (0.083, 0.7, 0.2),
            (0.5, 0.3, 0.6),
            (0.95, 1.0, 0.5),
            (0.2, 0.0, 1.0),
        ] {
            let (h, s, v) = oklch_to_hsb(hsb_to_oklch(hue, saturation, level));
            // A grey's hue is noise, so only chromatic colors keep theirs.
            if saturation > 0.0 {
                assert!(close(h, hue), "hue {hue} {saturation} {level}: got {h}");
            }
            assert!(close(s, saturation), "saturation {hue} {saturation} {level}: got {s}");
            assert!(close(v, level), "level {hue} {saturation} {level}: got {v}");
        }
    }

    #[test]
    fn black_and_white_are_achromatic() {
        let black = hsb_to_oklch(0.3, 1.0, 0.0);
        assert_eq!(black.l, 0.0);
        assert_eq!(black.c, 0.0);
        assert_eq!(oklch_to_hsb(black), (0.0, 0.0, 0.0));
        let white = hsb_to_oklch(0.3, 0.0, 1.0);
        assert!(close(white.l, 1.0));
        assert!(white.c <= ACHROMATIC_CHROMA);
    }

    /// Reference values shared with the Swift mirror (SceneColor).
    #[test]
    fn matches_reference_values() {
        let orange = hsb_to_oklch(0.083, 0.7, 0.2);
        assert!(close(orange.l, 0.265897893413141));
        assert!(close(orange.c, 0.04010684046563108));
        assert!(close(orange.h, 0.1788121486345366));
        let (h, s, v) = oklch_to_hsb(Oklch { l: 0.6329489434, c: 0.0200534202, h: 0.1788121486 });
        assert!((h - 0.079).abs() < 1e-3);
        assert!((s - 0.145).abs() < 1e-3);
        assert!((v - 0.576).abs() < 1e-3);
    }

    #[test]
    fn out_of_gamut_colors_clip_to_the_edge() {
        let (_, s, v) = oklch_to_hsb(Oklch { l: 0.9, c: 0.4, h: 0.1 });
        assert!((0.0..=1.0).contains(&s));
        assert!((0.0..=1.0).contains(&v));
    }
}
