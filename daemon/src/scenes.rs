//! Scenes: named per-light color/brightness programs.
//!
//! A scene maps each light it touches to a curve: points on a normalized
//! 0...1 timeline, linearly interpolated per channel and stepped over
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
use crate::store::Store;

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
    /// clients polling /lights see the scene's progress.
    pub async fn run(self, cache: Arc<LightCache>, cancel: CancellationToken) {
        if self.duration <= 0.0 {
            self.apply_frame(&cache, 1.0, None).await;
            return;
        }
        let interval = self.duration / CURVE_STEPS as f64;
        for i in 0..=CURVE_STEPS {
            if cancel.is_cancelled() {
                return;
            }
            self.apply_frame(&cache, i as f64 / CURVE_STEPS as f64, Some(STEP_FADE_SECS)).await;
            let cancelled = tokio::select! {
                _ = cancel.cancelled() => true,
                _ = tokio::time::sleep(Duration::from_secs_f64(interval)) => false,
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

/// The interpolated frame at timeline position `t` (clamped to the ends).
fn sample(points: &[Point], t: f64) -> Point {
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
    fn sample_interpolates_and_clamps() {
        let scene = one_light(vec![
            Point { t: 0.0, hue: 0.0, saturation: 1.0, level: 0.0 },
            Point { t: 0.5, hue: 0.2, saturation: 1.0, level: 1.0 },
        ]);
        let mid = sample(&scene.lights["1"], 0.25);
        assert!((mid.hue - 0.1).abs() < 1e-12);
        assert!((mid.level - 0.5).abs() < 1e-12);
        assert_eq!(sample(&scene.lights["1"], 0.9).level, 1.0); // clamped to last point
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
