//! Scenes: named per-light color/brightness programs.
//!
//! A scene maps each light it touches to a curve: points on a normalized
//! 0...1 timeline, monotone-cubic interpolated in Oklch (smooth, no
//! overshoot past keyframes, evenly paced to the eye) and stepped over
//! `duration` seconds. A solid color is a one-point, zero-duration curve; a
//! point with level 0 turns the light off (the app's invariant: a light is
//! off exactly when its brightness is 0). Lights not in the map are left
//! alone. A schedule is time-only — everything about *what* happens,
//! including which lights, lives in the scene.
//!
//! The sunrise/sunset presets carry huectl's field-tested keyframes; they're
//! instantiated per install (one curve per light) once the bridge is first
//! seen — see `seed_presets`.
//!
//! Author: Hamish M. Blair <hmblair@stanford.edu>

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio_util::sync::CancellationToken;
use tracing::info;

use crate::bridge::StateUpdate;
use crate::cache::LightCache;
use crate::color::{hsb_to_oklch, oklch_to_hsb, Oklch, ACHROMATIC_CHROMA};
use crate::store::Store;

/// Most steps a timed scene is sampled at (huectl's value).
const CURVE_STEPS: u32 = 120;
/// Floor on the step interval so short scenes don't hammer the bridge (a
/// 15 s preview steps every 0.5 s, not every 0.125 s).
const MIN_STEP_SECS: f64 = 0.5;
/// Levels at or below this are "off".
const OFF_THRESHOLD: f64 = 1e-9;

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug)]
#[serde(deny_unknown_fields)]
pub struct Point {
    /// Position on the scene's timeline, 0...1.
    pub t: f64,
    pub hue: f64,
    pub saturation: f64,
    /// Brightness; 0 turns the light off.
    pub level: f64,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(deny_unknown_fields)]
pub struct Scene {
    /// Total run time in seconds. 0 = apply the end state immediately.
    pub duration: f64,
    /// Curve per light id. Multiple lights sharing a curve simply repeat it.
    pub lights: BTreeMap<String, Vec<Point>>,
}

impl Scene {
    /// Validate and canonicalize (sorts each curve by t). Rejection happens
    /// at creation time, so schedules never carry a scene that fails at 7am.
    pub fn validate(&mut self) -> Result<(), String> {
        if !self.duration.is_finite() || self.duration < 0.0 {
            return Err("duration must be a non-negative number of seconds".into());
        }
        if self.lights.is_empty() {
            return Err("a scene needs at least one light".into());
        }
        for (light_id, points) in &mut self.lights {
            if points.is_empty() {
                return Err(format!("light {light_id} needs at least one point"));
            }
            for p in points.iter() {
                for (field, value) in [("t", p.t), ("hue", p.hue), ("saturation", p.saturation), ("level", p.level)] {
                    if !value.is_finite() || !(0.0..=1.0).contains(&value) {
                        return Err(format!("light {light_id}: point {field} must be in 0...1, got {value}"));
                    }
                }
            }
            points.sort_by(|a, b| a.t.partial_cmp(&b.t).expect("finite by validation"));
            if points.windows(2).any(|w| w[1].t - w[0].t < 1e-9) {
                return Err(format!("light {light_id}: points share the same t"));
            }
        }
        Ok(())
    }

    pub fn duration(&self) -> Duration {
        Duration::from_secs_f64(self.duration)
    }

    /// The lights this scene touches — what it owns while running.
    pub fn light_ids(&self) -> Vec<String> {
        self.lights.keys().cloned().collect()
    }

    /// Run to completion or cancellation, writing through the cache so
    /// clients polling /lights see the scene's progress. `elapsed` is how
    /// far into the timeline the run starts, so a scene whose window is
    /// already open joins at the right frame instead of restarting.
    ///
    /// Paced by wall clock: each step sleeps *until* its scheduled moment
    /// rather than sleeping a fixed interval after its writes, so bridge
    /// write latency doesn't stretch the scene past its duration (a 15 s
    /// preview must take 15 s — clients sync UI to that). Steps fade over
    /// one interval, so the curve reads as continuous at any step rate.
    pub async fn run(self, cache: Arc<LightCache>, cancel: CancellationToken, elapsed: Duration) {
        if self.duration <= 0.0 {
            self.apply_frame(&cache, 1.0, None).await;
            return;
        }
        let interval = (self.duration / CURVE_STEPS as f64).max(MIN_STEP_SECS);
        let steps = (self.duration / interval).ceil().max(1.0) as u32;
        let first = first_step(elapsed, interval, steps);
        let start = tokio::time::Instant::now();
        for i in first..=steps {
            if cancel.is_cancelled() {
                return;
            }
            // The first frame enters quickly — fading into it over a full
            // interval visibly interpolated from whatever the lights were
            // doing (a 1h scene took 30s to reach its own starting state).
            // Subsequent frames fade over the interval for smoothness.
            let fade = if i == first { MIN_STEP_SECS } else { interval };
            self.apply_frame(&cache, i as f64 / steps as f64, Some(fade)).await;
            if i == steps {
                return;
            }
            let target = start + step_due(i + 1, interval, elapsed);
            let cancelled = tokio::select! {
                _ = cancel.cancelled() => true,
                _ = tokio::time::sleep_until(target) => false,
            };
            if cancelled {
                return;
            }
        }
    }

    /// Write every light's interpolated state at timeline position `t`.
    async fn apply_frame(&self, cache: &LightCache, t: f64, transition: Option<f64>) {
        for (light_id, points) in &self.lights {
            let state = frame_state(sample(points, t), transition);
            if let Err(e) = cache.apply(light_id, &state).await {
                tracing::warn!("Scene write to light {light_id} failed: {e}");
            }
        }
    }
}

/// The step a run joins at when `elapsed` of the timeline has already
/// passed: the last step whose moment is not after `elapsed`.
fn first_step(elapsed: Duration, interval: f64, steps: u32) -> u32 {
    ((elapsed.as_secs_f64() / interval).floor() as u32).min(steps)
}

/// How long after the run starts step `i` is due, given the timeline
/// already had `elapsed` behind it when the run started.
fn step_due(i: u32, interval: f64, elapsed: Duration) -> Duration {
    Duration::from_secs_f64(interval * i as f64).saturating_sub(elapsed)
}

/// The interpolated frame at timeline position `t` (clamped to the ends).
/// Keyframes convert to Oklch, and each of lightness, chroma and hue
/// follows a monotone cubic spline through them — smooth, never
/// overshooting past a keyframe (a sunrise can't dip darker than its
/// darkest point), and evenly paced to the eye. Hue is circular and takes
/// the short way around the wheel (see `unwrap_hues`). The Swift editor
/// draws the same math (SceneCurve).
fn sample(points: &[Point], t: f64) -> Point {
    let xs: Vec<f64> = points.iter().map(|p| p.t).collect();
    let colors: Vec<Oklch> = points.iter().map(|p| hsb_to_oklch(p.hue, p.saturation, p.level)).collect();
    let channel = |ys: Vec<f64>| interp_channel(&xs, &ys, t);
    let color = Oklch {
        l: channel(colors.iter().map(|c| c.l).collect()),
        c: channel(colors.iter().map(|c| c.c).collect()).max(0.0),
        h: channel(unwrap_hues(&chromatic_hues(&colors))).rem_euclid(1.0),
    };
    let (hue, saturation, level) = oklch_to_hsb(color);
    Point { t, hue, saturation: saturation.clamp(0.0, 1.0), level: level.clamp(0.0, 1.0) }
}

/// The hue of each color, with achromatic colors (greys, black, white)
/// taking the hue of the nearest chromatic neighbor — their own hue is
/// noise, and a fade from white to orange should hold orange throughout
/// rather than sweep the wheel.
fn chromatic_hues(colors: &[Oklch]) -> Vec<f64> {
    let first = colors.iter().find(|c| c.c > ACHROMATIC_CHROMA).map(|c| c.h).unwrap_or(0.0);
    let mut carried = first;
    colors
        .iter()
        .map(|color| {
            if color.c > ACHROMATIC_CHROMA {
                carried = color.h;
            }
            carried
        })
        .collect()
}

/// Hue is a circle (0 and 1 are the same red), but the spline interpolates
/// on a line — so unwrap the hue sequence first: shift each value by whole
/// turns until it sits within half a turn of its predecessor. Interpolation
/// then takes the short way around the wheel (0.95 -> 0.05 crosses red, not
/// the long way through green), and samples wrap back into 0...1.
fn unwrap_hues(hues: &[f64]) -> Vec<f64> {
    let mut unwrapped: Vec<f64> = Vec::with_capacity(hues.len());
    for &hue in hues {
        let shifted = match unwrapped.last() {
            Some(prev) => {
                let mut hue = hue;
                while hue - prev > 0.5 {
                    hue -= 1.0;
                }
                while prev - hue > 0.5 {
                    hue += 1.0;
                }
                hue
            }
            None => hue,
        };
        unwrapped.push(shifted);
    }
    unwrapped
}

/// Monotone cubic interpolation (Fritsch–Carlson), one channel. With two
/// points it reduces to linear. `xs` is strictly increasing (validated).
fn interp_channel(xs: &[f64], ys: &[f64], t: f64) -> f64 {
    let n = xs.len();
    if n == 1 || t <= xs[0] {
        return ys[0];
    }
    if t >= xs[n - 1] {
        return ys[n - 1];
    }

    // Secant slopes per interval, then tangents per point.
    let d: Vec<f64> = (0..n - 1).map(|i| (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i])).collect();
    let mut m = vec![0.0; n];
    m[0] = d[0];
    m[n - 1] = d[n - 2];
    for i in 1..n - 1 {
        // A tangent of 0 at local extrema keeps the curve monotone per side.
        m[i] = if d[i - 1] * d[i] <= 0.0 { 0.0 } else { (d[i - 1] + d[i]) / 2.0 };
    }
    // Fritsch–Carlson limiter: clamp tangents so no interval overshoots.
    for i in 0..n - 1 {
        if d[i] == 0.0 {
            m[i] = 0.0;
            m[i + 1] = 0.0;
            continue;
        }
        let a = m[i] / d[i];
        let b = m[i + 1] / d[i];
        let s = a * a + b * b;
        if s > 9.0 {
            let tau = 3.0 / s.sqrt();
            m[i] = tau * a * d[i];
            m[i + 1] = tau * b * d[i];
        }
    }

    // Cubic Hermite on the containing interval.
    let i = xs.windows(2).position(|w| t < w[1]).unwrap_or(n - 2);
    let h = xs[i + 1] - xs[i];
    let s = (t - xs[i]) / h;
    let h00 = (1.0 + 2.0 * s) * (1.0 - s) * (1.0 - s);
    let h10 = s * (1.0 - s) * (1.0 - s);
    let h01 = s * s * (3.0 - 2.0 * s);
    let h11 = s * s * (s - 1.0);
    h00 * ys[i] + h10 * h * m[i] + h01 * ys[i + 1] + h11 * h * m[i + 1]
}

/// A frame as a light write: level 0 is "off", anything else is on at that
/// color, optionally fading over `transition` seconds.
fn frame_state(frame: Point, transition: Option<f64>) -> StateUpdate {
    if frame.level <= OFF_THRESHOLD {
        StateUpdate {
            on: Some(false),
            transition,
            ..Default::default()
        }
    } else {
        StateUpdate {
            on: Some(true),
            hue: Some(frame.hue),
            saturation: Some(frame.saturation),
            level: Some(frame.level),
            transition,
        }
    }
}

/// The built-in preset curves (huectl's keyframes, normalized).
fn preset_curves() -> Vec<(&'static str, f64, Vec<Point>)> {
    let p = |t: f64, hue: f64, sat: f64, bri: f64| Point {
        t,
        hue: hue / 65_535.0,
        saturation: sat / 254.0,
        level: bri / 254.0,
    };
    vec![
        (
            "sunrise",
            3_600.0,
            vec![
                p(0.00, 0.0, 254.0, 1.0),        // deep red, minimum brightness
                p(0.33, 5_000.0, 254.0, 84.0),   // orange
                p(0.66, 10_000.0, 194.0, 168.0), // warm yellow
                p(1.00, 10_000.0, 50.0, 254.0),  // warm white, full brightness
            ],
        ),
        (
            "sunset",
            3_600.0,
            vec![
                p(0.00, 10_000.0, 50.0, 254.0),
                p(0.33, 10_000.0, 194.0, 168.0),
                p(0.66, 5_000.0, 254.0, 84.0),
                Point { t: 1.0, hue: 0.0, saturation: 1.0, level: 0.0 }, // fade to off
            ],
        ),
    ]
}

/// Seed sunrise/sunset into an empty scene store once the bridge is first
/// seen, instantiated with the install's actual light ids (scenes are
/// strictly per-light; there is no "all lights" wildcard).
pub fn spawn_preset_seeder(scenes: Arc<Store<Scene>>, cache: Arc<LightCache>) {
    tokio::spawn(async move {
        loop {
            if !scenes.map().await.is_empty() {
                return;
            }
            if let Some(lights) = cache.snapshot().await {
                let ids: Vec<String> = lights.iter().map(|l| l.id.clone()).collect();
                for (name, duration, points) in preset_curves() {
                    let scene = Scene {
                        duration,
                        lights: ids.iter().map(|id| (id.clone(), points.clone())).collect(),
                    };
                    scenes.upsert(name.to_string(), scene).await;
                }
                info!("Seeded preset scenes for {} light(s)", ids.len());
                return;
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn one_light(points: Vec<Point>) -> Scene {
        let mut scene = Scene {
            duration: 60.0,
            lights: BTreeMap::from([("1".to_string(), points)]),
        };
        scene.validate().unwrap();
        scene
    }

    #[test]
    fn run_joins_a_timeline_part_way_through() {
        let interval = 30.0;
        assert_eq!(first_step(Duration::ZERO, interval, 120), 0);
        assert_eq!(first_step(Duration::from_secs(45), interval, 120), 1);
        assert_eq!(first_step(Duration::from_secs(60), interval, 120), 2);
        assert_eq!(first_step(Duration::from_secs(9_000), interval, 120), 120);
        assert_eq!(step_due(2, interval, Duration::from_secs(45)), Duration::from_secs(15));
        assert_eq!(step_due(1, interval, Duration::from_secs(45)), Duration::ZERO);
    }

    #[test]
    fn validate_rejects_bad_scenes() {
        assert!(Scene { duration: 60.0, lights: BTreeMap::new() }.validate().is_err());
        let point = Point { t: 0.0, hue: 0.0, saturation: 0.0, level: 1.0 };
        assert!(Scene {
            duration: -1.0,
            lights: BTreeMap::from([("1".to_string(), vec![point])]),
        }
        .validate()
        .is_err());
        assert!(Scene {
            duration: 60.0,
            lights: BTreeMap::from([("1".to_string(), vec![])]),
        }
        .validate()
        .is_err());
        let bad = Point { t: 0.0, hue: 1.5, saturation: 0.0, level: 1.0 };
        assert!(Scene {
            duration: 60.0,
            lights: BTreeMap::from([("1".to_string(), vec![bad])]),
        }
        .validate()
        .is_err());
    }

    #[test]
    fn validate_sorts_each_curve() {
        let scene = one_light(vec![
            Point { t: 1.0, hue: 0.5, saturation: 0.5, level: 1.0 },
            Point { t: 0.0, hue: 0.0, saturation: 0.0, level: 0.0 },
        ]);
        assert_eq!(scene.lights["1"][0].t, 0.0);
    }

    #[test]
    fn sample_is_linear_in_oklch_with_two_points_and_clamps() {
        let a = Point { t: 0.0, hue: 0.083, saturation: 0.5, level: 0.3 };
        let b = Point { t: 0.5, hue: 0.083, saturation: 0.5, level: 1.0 };
        let scene = one_light(vec![a, b]);
        let mid = sample(&scene.lights["1"], 0.25);
        let (start, end) = (hsb_to_oklch(a.hue, a.saturation, a.level), hsb_to_oklch(b.hue, b.saturation, b.level));
        let got = hsb_to_oklch(mid.hue, mid.saturation, mid.level);
        assert!((got.l - (start.l + end.l) / 2.0).abs() < 1e-6);
        assert!((got.c - (start.c + end.c) / 2.0).abs() < 1e-6);
        assert!((sample(&scene.lights["1"], 0.9).level - 1.0).abs() < 1e-6); // clamped to last point
    }

    #[test]
    fn white_to_orange_holds_orange_throughout() {
        let scene = one_light(vec![
            Point { t: 0.0, hue: 0.3, saturation: 0.0, level: 1.0 },
            Point { t: 1.0, hue: 0.083, saturation: 0.7, level: 0.2 },
        ]);
        let points = &scene.lights["1"];
        for i in 1..=20 {
            let hue = sample(points, i as f64 / 20.0).hue;
            assert!((hue - 0.083).abs() < 0.01, "sample {i}: hue {hue} drifted");
        }
    }

    #[test]
    fn fade_to_off_ends_exactly_off() {
        let scene = one_light(vec![
            Point { t: 0.0, hue: 0.083, saturation: 0.7, level: 0.5 },
            Point { t: 1.0, hue: 0.0, saturation: 1.0, level: 0.0 },
        ]);
        let points = &scene.lights["1"];
        assert_eq!(sample(points, 1.0).level, 0.0);
        assert!(sample(points, 0.99).level > 0.0);
    }

    #[test]
    fn spline_hits_keyframes_and_never_overshoots() {
        let p = |t: f64, level: f64| Point { t, hue: 0.1, saturation: 0.5, level };
        let scene = one_light(vec![p(0.0, 0.0), p(0.4, 1.0), p(0.6, 1.0), p(1.0, 0.2)]);
        let points = &scene.lights["1"];
        for kf in points.iter() {
            assert!((sample(points, kf.t).level - kf.level).abs() < 1e-6);
        }
        // Monotone: the plateau between 0.4 and 0.6 stays flat at 1.0 (no
        // bulge above the keyframes), and nothing exceeds the keyframe range.
        assert!((sample(points, 0.5).level - 1.0).abs() < 1e-9);
        for i in 0..=100 {
            let level = sample(points, i as f64 / 100.0).level;
            assert!((0.0..=1.0).contains(&level));
        }
    }

    #[test]
    fn validate_rejects_duplicate_times() {
        let p = |t: f64| Point { t, hue: 0.1, saturation: 0.5, level: 0.5 };
        let mut scene = Scene {
            duration: 60.0,
            lights: BTreeMap::from([("1".to_string(), vec![p(0.3), p(0.3)])]),
        };
        assert!(scene.validate().is_err());
    }

    #[test]
    fn hue_takes_the_short_way_around_the_wheel() {
        let p = |t: f64, hue: f64| Point { t, hue, saturation: 1.0, level: 0.5 };
        let scene = one_light(vec![p(0.0, 0.95), p(1.0, 0.05)]);
        let points = &scene.lights["1"];
        // Every sample stays near the red wrap point — never out through
        // green (hue ~0.3-0.7) as un-wrapped interpolation would go.
        for i in 0..=20 {
            let hue = sample(points, i as f64 / 20.0).hue;
            let wrap_distance = hue.min(1.0 - hue);
            assert!(
                wrap_distance <= 0.051,
                "sample {i}: hue {hue} strayed from the wrap point"
            );
        }
        let mid = sample(points, 0.5).hue;
        assert!(mid.min(1.0 - mid) < 0.01, "midpoint {mid} should sit at red");
    }

    #[test]
    fn zero_level_frame_is_off() {
        let state = frame_state(Point { t: 1.0, hue: 0.3, saturation: 1.0, level: 0.0 }, None);
        assert_eq!(state.on, Some(false));
        assert!(state.hue.is_none());
    }

    #[test]
    fn presets_validate_when_instantiated() {
        for (name, duration, points) in preset_curves() {
            let mut scene = Scene {
                duration,
                lights: BTreeMap::from([("1".to_string(), points)]),
            };
            assert!(scene.validate().is_ok(), "preset {name} invalid");
        }
    }
}
