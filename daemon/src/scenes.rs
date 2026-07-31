//! Scenes: named color/brightness presets a schedule (or a user) applies to
//! lights.
//!
//! A scene is a curve — points on a normalized 0...1 timeline, linearly
//! interpolated per channel and stepped over `duration` seconds. A solid
//! color is simply the one-point, zero-duration case: it applies its color
//! and finishes immediately, so it never meaningfully holds ownership. A
//! point with level 0 turns the lights off (the app's invariant: a light is
//! off exactly when its brightness is 0).
//!
//! The sunrise/sunset presets carry huectl's field-tested keyframes,
//! expressed in the same format user-authored scenes use.
//!
//! Author: Hamish M. Blair <hmblair@stanford.edu>

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio_util::sync::CancellationToken;

use crate::bridge::StateUpdate;
use crate::cache::LightCache;

/// Steps a timed scene is sampled at (huectl's value).
const CURVE_STEPS: u32 = 120;
/// Per-step fade so the curve reads as continuous rather than stepped.
const STEP_FADE_SECS: f64 = 0.5;
/// Levels at or below this are "off".
const OFF_THRESHOLD: f64 = 1e-9;

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug)]
#[serde(deny_unknown_fields)]
pub struct Point {
    /// Position on the scene's timeline, 0...1.
    pub t: f64,
    pub hue: f64,
    pub saturation: f64,
    /// Brightness; 0 turns the lights off.
    pub level: f64,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(deny_unknown_fields)]
pub struct Scene {
    /// Total run time in seconds. 0 = apply the end state immediately.
    pub duration: f64,
    pub points: Vec<Point>,
}

impl Scene {
    /// Validate and canonicalize (sorts points by t). Rejection happens at
    /// creation time, so schedules never carry a scene that fails at 7am.
    pub fn validate(&mut self) -> Result<(), String> {
        if self.points.is_empty() {
            return Err("a scene needs at least one point".into());
        }
        if !self.duration.is_finite() || self.duration < 0.0 {
            return Err("duration must be a non-negative number of seconds".into());
        }
        for p in &self.points {
            for (field, value) in [("t", p.t), ("hue", p.hue), ("saturation", p.saturation), ("level", p.level)] {
                if !value.is_finite() || !(0.0..=1.0).contains(&value) {
                    return Err(format!("point {field} must be in 0...1, got {value}"));
                }
            }
        }
        self.points
            .sort_by(|a, b| a.t.partial_cmp(&b.t).expect("finite by validation"));
        Ok(())
    }

    pub fn duration(&self) -> Duration {
        Duration::from_secs_f64(self.duration)
    }

    /// The interpolated frame at timeline position `t` (clamped to the ends).
    fn sample(&self, t: f64) -> Point {
        let points = &self.points;
        let first = points.first().expect("validated non-empty");
        let last = points.last().expect("validated non-empty");
        if t <= first.t {
            return *first;
        }
        if t >= last.t {
            return *last;
        }
        let after = points.iter().position(|p| p.t >= t).expect("t < last.t");
        let (a, b) = (&points[after - 1], &points[after]);
        let span = b.t - a.t;
        // Coincident points: the later one wins, matching sort stability.
        let f = if span <= 0.0 { 1.0 } else { (t - a.t) / span };
        let lerp = |x: f64, y: f64| x + f * (y - x);
        Point {
            t,
            hue: lerp(a.hue, b.hue),
            saturation: lerp(a.saturation, b.saturation),
            level: lerp(a.level, b.level),
        }
    }

    /// Run to completion or cancellation, writing through the cache so
    /// clients polling /lights see the scene's progress.
    pub async fn run(self, cache: Arc<LightCache>, targets: Vec<String>, cancel: CancellationToken) {
        if self.duration <= 0.0 {
            // Instant scene: apply the end state and finish.
            cache.apply_many(&targets, &frame_state(self.sample(1.0), None)).await;
            return;
        }
        let interval = self.duration / CURVE_STEPS as f64;
        for i in 0..=CURVE_STEPS {
            if cancel.is_cancelled() {
                return;
            }
            let frame = self.sample(i as f64 / CURVE_STEPS as f64);
            cache.apply_many(&targets, &frame_state(frame, Some(STEP_FADE_SECS))).await;
            let cancelled = tokio::select! {
                _ = cancel.cancelled() => true,
                _ = tokio::time::sleep(Duration::from_secs_f64(interval)) => false,
            };
            if cancelled {
                return;
            }
        }
    }
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

/// Built-in presets, seeded into the scene store on first run and editable
/// like any user scene. Values are huectl's sunrise/sunset breakpoints,
/// normalized.
pub fn default_scenes() -> BTreeMap<String, Scene> {
    let p = |t: f64, hue: f64, sat: f64, bri: f64| Point {
        t,
        hue: hue / 65_535.0,
        saturation: sat / 254.0,
        level: bri / 254.0,
    };
    BTreeMap::from([
        (
            "sunrise".to_string(),
            Scene {
                duration: 3_600.0,
                points: vec![
                    p(0.00, 0.0, 254.0, 1.0),       // deep red, minimum brightness
                    p(0.33, 5_000.0, 254.0, 84.0),  // orange
                    p(0.66, 10_000.0, 194.0, 168.0), // warm yellow
                    p(1.00, 10_000.0, 50.0, 254.0), // warm white, full brightness
                ],
            },
        ),
        (
            "sunset".to_string(),
            Scene {
                duration: 3_600.0,
                points: vec![
                    p(0.00, 10_000.0, 50.0, 254.0),
                    p(0.33, 10_000.0, 194.0, 168.0),
                    p(0.66, 5_000.0, 254.0, 84.0),
                    Point { t: 1.0, hue: 0.0, saturation: 1.0, level: 0.0 }, // fade to off
                ],
            },
        ),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn curve(points: Vec<Point>) -> Scene {
        let mut scene = Scene { duration: 60.0, points };
        scene.validate().unwrap();
        scene
    }

    #[test]
    fn validate_rejects_bad_scenes() {
        assert!(Scene { duration: 60.0, points: vec![] }.validate().is_err());
        assert!(Scene {
            duration: -1.0,
            points: vec![Point { t: 0.0, hue: 0.0, saturation: 0.0, level: 1.0 }],
        }
        .validate()
        .is_err());
        assert!(Scene {
            duration: 60.0,
            points: vec![Point { t: 0.0, hue: 1.5, saturation: 0.0, level: 1.0 }],
        }
        .validate()
        .is_err());
    }

    #[test]
    fn validate_sorts_points() {
        let scene = curve(vec![
            Point { t: 1.0, hue: 0.5, saturation: 0.5, level: 1.0 },
            Point { t: 0.0, hue: 0.0, saturation: 0.0, level: 0.0 },
        ]);
        assert_eq!(scene.points[0].t, 0.0);
    }

    #[test]
    fn sample_interpolates_and_clamps() {
        let scene = curve(vec![
            Point { t: 0.0, hue: 0.0, saturation: 1.0, level: 0.0 },
            Point { t: 0.5, hue: 0.2, saturation: 1.0, level: 1.0 },
        ]);
        let mid = scene.sample(0.25);
        assert!((mid.hue - 0.1).abs() < 1e-12);
        assert!((mid.level - 0.5).abs() < 1e-12);
        assert_eq!(scene.sample(0.9).level, 1.0); // clamped to last point
    }

    #[test]
    fn zero_level_frame_is_off() {
        let state = frame_state(Point { t: 1.0, hue: 0.3, saturation: 1.0, level: 0.0 }, None);
        assert_eq!(state.on, Some(false));
        assert!(state.hue.is_none());
    }

    #[test]
    fn presets_validate() {
        for (name, scene) in default_scenes() {
            let mut scene = scene;
            assert!(scene.validate().is_ok(), "preset {name} invalid");
        }
    }
}
