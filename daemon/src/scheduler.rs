//! Schedules: run a scene at a time of day, on chosen weekdays or once on a
//! date. Orthogonal to what the scene is — a schedule only references one by
//! name.
//!
//! `at` is a wall-clock "HH:MM", or the literals "sunrise"/"sunset" —
//! resolved each tick against the location configured in config.env, so a
//! solar schedule tracks the seasons with no further input.
//!
//! A schedule is due for as long as its window is open: from its start time
//! until the scene's duration has passed (at least one minute for instant
//! scenes). The loop ticks every 30 s and fires each version of a schedule
//! at most once per day, so a schedule added or edited inside its window
//! starts its scene at the matching point of the timeline, and a restart
//! inside the window resumes the scene rather than losing it. A run whose
//! schedule or scene is edited, or whose schedule is disabled or deleted,
//! stops; if the window is still open the next tick starts the new version
//! at the matching point. One-shot schedules delete themselves once their
//! window has closed.
//!
//! Author: Hamish M. Blair <hmblair@stanford.edu>

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Datelike, Local, NaiveDate, Timelike};
use serde::{Deserialize, Serialize};
use sunrise::{Coordinates, SolarDay, SolarEvent};
use tracing::{info, warn};

use crate::runner::SceneRunner;
use crate::scenes::Scene;
use crate::store::Store;

const TICK: Duration = Duration::from_secs(30);
/// Shortest window a schedule stays due for, so an instant scene still
/// fires when the daemon reaches its minute.
const MIN_WINDOW: Duration = Duration::from_secs(60);
const DAY_NAMES: [&str; 7] = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];

fn default_true() -> bool {
    true
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(deny_unknown_fields)]
pub struct Schedule {
    /// "HH:MM" in the box's local timezone, or "sunrise"/"sunset".
    pub at: String,
    /// Weekdays to fire on: ["mon", ..., "sun"]. Ignored when `on` is set.
    #[serde(default)]
    pub days: Vec<String>,
    /// One-shot date "YYYY-MM-DD"; the schedule deletes itself once its
    /// window on that date has closed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on: Option<String>,
    /// Name of the scene to run. The scene carries everything about *what*
    /// happens, including which lights; a schedule is time-only.
    pub scene: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum At {
    Clock { hour: u32, minute: u32 },
    Sunrise,
    Sunset,
}

impl Schedule {
    /// Validate and canonicalize (lowercases `at` and day names). The scene
    /// reference — and, for solar times, the presence of a location — is
    /// checked by the API layer.
    pub fn validate(&mut self) -> Result<(), String> {
        self.at = self.at.trim().to_lowercase();
        parse_at(&self.at)?;
        for day in &mut self.days {
            *day = day.to_lowercase();
            if !DAY_NAMES.contains(&day.as_str()) {
                return Err(format!("unknown day '{day}' (use mon...sun)"));
            }
        }
        if let Some(date) = &self.on {
            NaiveDate::parse_from_str(date, "%Y-%m-%d")
                .map_err(|_| format!("invalid date '{date}' (use YYYY-MM-DD)"))?;
        } else if self.days.is_empty() {
            return Err("a schedule needs either `days` or a one-shot `on` date".into());
        }
        Ok(())
    }

    pub fn is_solar(&self) -> bool {
        matches!(parse_at(&self.at), Ok(At::Sunrise | At::Sunset))
    }

    /// The one-shot date, if the schedule has one.
    fn one_shot_date(&self) -> Option<NaiveDate> {
        NaiveDate::parse_from_str(self.on.as_deref()?, "%Y-%m-%d").ok()
    }

    /// Whether the schedule runs on `now`'s date. The day filter applies to
    /// today for every time form — the bare solar events always land on
    /// their own local day.
    fn runs_on(&self, now: &DateTime<Local>) -> bool {
        match self.one_shot_date() {
            Some(date) => date == now.date_naive(),
            None => {
                let day = DAY_NAMES[now.weekday().num_days_from_monday() as usize];
                self.days.iter().any(|d| d == day)
            }
        }
    }

    /// When the schedule starts on `now`'s date, or None if it does not run
    /// that day or its time cannot be resolved.
    fn start_today(&self, now: &DateTime<Local>, location: Option<Coordinates>) -> Option<DateTime<Local>> {
        if !self.runs_on(now) {
            return None;
        }
        match parse_at(&self.at).ok()? {
            At::Clock { hour, minute } => clock_time(now, hour, minute),
            At::Sunrise => solar_datetime(location, SolarEvent::Sunrise, now),
            At::Sunset => solar_datetime(location, SolarEvent::Sunset, now),
        }
    }

    /// Whether the schedule's window covers `now`.
    #[cfg(test)]
    fn is_due(&self, now: &DateTime<Local>, location: Option<Coordinates>, duration: Duration) -> bool {
        match self.start_today(now, location) {
            Some(start) => window_covers(start, duration, now),
            None => false,
        }
    }

    /// Whether a one-shot schedule can never fire again: its date has
    /// passed, or its window on that date has closed.
    fn is_expired(&self, now: &DateTime<Local>, location: Option<Coordinates>, duration: Duration) -> bool {
        let Some(date) = self.one_shot_date() else {
            return false;
        };
        if date < now.date_naive() {
            return true;
        }
        match self.start_today(now, location) {
            Some(start) => *now >= window_end(start, duration),
            None => false,
        }
    }
}

/// Whether the window that opens at `start` and stays open for the scene's
/// duration covers `now`.
fn window_covers(start: DateTime<Local>, duration: Duration, now: &DateTime<Local>) -> bool {
    start <= *now && *now < window_end(start, duration)
}

/// The moment a window that opened at `start` closes.
fn window_end(start: DateTime<Local>, duration: Duration) -> DateTime<Local> {
    start + chrono::Duration::from_std(duration.max(MIN_WINDOW)).unwrap_or(chrono::Duration::zero())
}

/// The wall-clock `hour:minute` on `now`'s date.
fn clock_time(now: &DateTime<Local>, hour: u32, minute: u32) -> Option<DateTime<Local>> {
    now.date_naive().and_hms_opt(hour, minute, 0)?.and_local_timezone(Local).single()
}

/// The local moment of the event on `now`'s date. None without a location —
/// or during polar day/night, when the event doesn't happen — leaving the
/// schedule dormant rather than firing at some wrong time.
fn solar_datetime(
    location: Option<Coordinates>,
    event: SolarEvent,
    now: &DateTime<Local>,
) -> Option<DateTime<Local>> {
    let time = SolarDay::new(location?, now.date_naive()).event_time(event)?;
    Some(time.with_timezone(&Local))
}

/// Today's local hour/minute of the event, for GET /config's display copy.
pub(crate) fn solar_time(
    location: Option<Coordinates>,
    event: SolarEvent,
    now: &DateTime<Local>,
) -> Option<(u32, u32)> {
    let time = solar_datetime(location, event, now)?;
    Some((time.hour(), time.minute()))
}

fn parse_at(at: &str) -> Result<At, String> {
    match at {
        "sunrise" => return Ok(At::Sunrise),
        "sunset" => return Ok(At::Sunset),
        _ => {}
    }
    let err = || format!("invalid time '{at}' (use HH:MM, sunrise, or sunset)");
    let (h, m) = at.split_once(':').ok_or_else(err)?;
    let hour: u32 = h.parse().map_err(|_| err())?;
    let minute: u32 = m.parse().map_err(|_| err())?;
    if hour > 23 || minute > 59 {
        return Err(err());
    }
    Ok(At::Clock { hour, minute })
}

/// The content of a schedule and its scene as one string, so an edit to
/// either reads as a new version.
fn fingerprint(schedule: &Schedule, scene: Option<&Scene>) -> String {
    serde_json::to_string(&(schedule, scene)).expect("serializable schedule and scene")
}

/// The last fire of a schedule: which day, and which version of the
/// schedule and scene.
struct Fired {
    date: NaiveDate,
    fingerprint: String,
}

/// Fires of each schedule by name. In-memory only; a restart inside a
/// window re-fires the schedule, which resumes its scene at the right point.
struct FiredLog {
    fires: HashMap<String, Fired>,
}

impl FiredLog {
    fn new() -> Self {
        FiredLog { fires: HashMap::new() }
    }

    /// Whether this version of the schedule and scene already fired on
    /// `now`'s date.
    fn contains(&self, name: &str, schedule: &Schedule, scene: Option<&Scene>, now: &DateTime<Local>) -> bool {
        match self.fires.get(name) {
            Some(fired) => {
                fired.date == now.date_naive() && fired.fingerprint == fingerprint(schedule, scene)
            }
            None => false,
        }
    }

    fn record(&mut self, name: &str, schedule: &Schedule, scene: Option<&Scene>, now: &DateTime<Local>) {
        let fired = Fired { date: now.date_naive(), fingerprint: fingerprint(schedule, scene) };
        self.fires.insert(name.to_string(), fired);
    }

    /// The version of the schedule that last fired, if any.
    fn fingerprint_of(&self, name: &str) -> Option<&str> {
        self.fires.get(name).map(|fired| fired.fingerprint.as_str())
    }
}

/// The version the running scene should still answer to: the current
/// content of its schedule and scene, if the schedule still exists and is
/// enabled.
fn live_fingerprint(schedule: Option<&Schedule>, scene: Option<&Scene>) -> Option<String> {
    schedule.filter(|s| s.enabled).map(|s| fingerprint(s, scene))
}

/// Stop the running scene if its schedule or scene was edited, or its
/// schedule disabled or deleted, since it fired, so the next tick
/// re-evaluates from scratch.
async fn stop_stale_run(
    runner: &SceneRunner,
    schedules: &Store<Schedule>,
    scenes: &Store<Scene>,
    fired: &FiredLog,
) {
    let Some(running) = runner.status().await else {
        return;
    };
    let Some(name) = running.schedule else {
        return;
    };
    let schedule = schedules.get(&name).await;
    let scene = match &schedule {
        Some(schedule) => scenes.get(&schedule.scene).await,
        None => None,
    };
    let live = live_fingerprint(schedule.as_ref(), scene.as_ref());
    if live.as_deref() != fired.fingerprint_of(&name) {
        info!("Schedule '{name}' or its scene changed; stopping scene '{}'", running.scene);
        runner.stop().await;
    }
}

/// The scene's duration, or zero when the scene is missing.
fn scene_duration(scene: Option<&Scene>) -> Duration {
    scene.map(Scene::duration).unwrap_or(Duration::ZERO)
}

/// Start the schedule's scene at the point of its timeline matching `now`.
async fn fire(
    name: &str,
    schedule: &Schedule,
    scene: Option<&Scene>,
    runner: &Arc<SceneRunner>,
    start: DateTime<Local>,
) -> bool {
    let Some(scene) = scene else {
        warn!("Schedule '{name}' references missing scene '{}'", schedule.scene);
        return false;
    };
    info!("Schedule '{name}' firing scene '{}'", schedule.scene);
    match runner.run(&schedule.scene, scene.clone(), Some(name.to_string()), start).await {
        Ok(()) => true,
        Err(running) => {
            info!("Schedule '{name}' deferred: scene '{running}' is still running");
            false
        }
    }
}

/// One pass over every schedule: drop expired one-shots and fire whatever
/// is due and has not fired yet. A fire deferred behind a running scene is
/// not recorded, so it retries while the window stays open.
async fn tick(
    schedules: &Store<Schedule>,
    scenes: &Store<Scene>,
    runner: &Arc<SceneRunner>,
    location: Option<Coordinates>,
    fired: &mut FiredLog,
) {
    let now = Local::now();
    stop_stale_run(runner, schedules, scenes, fired).await;
    for (name, schedule) in schedules.map().await {
        let scene = scenes.get(&schedule.scene).await;
        let duration = scene_duration(scene.as_ref());
        if schedule.is_expired(&now, location, duration) {
            info!("Schedule '{name}' one-shot window closed; removing");
            schedules.remove(&name).await;
            continue;
        }
        if !schedule.enabled || fired.contains(&name, &schedule, scene.as_ref(), &now) {
            continue;
        }
        let Some(start) = schedule.start_today(&now, location) else {
            continue;
        };
        if !window_covers(start, duration, &now) {
            continue;
        }
        if fire(&name, &schedule, scene.as_ref(), runner, start).await {
            fired.record(&name, &schedule, scene.as_ref(), &now);
        }
    }
}

pub fn spawn_scheduler(
    schedules: Arc<Store<Schedule>>,
    scenes: Arc<Store<Scene>>,
    runner: Arc<SceneRunner>,
    location: Option<Coordinates>,
) {
    tokio::spawn(async move {
        let mut fired = FiredLog::new();
        loop {
            tick(&schedules, &scenes, &runner, location, &mut fired).await;
            tokio::time::sleep(TICK).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use std::collections::BTreeMap;

    fn schedule(at: &str, days: &[&str]) -> Schedule {
        Schedule {
            at: at.into(),
            days: days.iter().map(|d| d.to_string()).collect(),
            on: None,
            scene: "sunrise".into(),
            enabled: true,
        }
    }

    #[test]
    fn validate_checks_time_days_and_date() {
        assert!(schedule("07:00", &["mon"]).validate().is_ok());
        assert!(schedule("7:5", &["sun"]).validate().is_ok());
        assert!(schedule("24:00", &["mon"]).validate().is_err());
        assert!(schedule("noon", &["mon"]).validate().is_err());
        assert!(schedule("07:00", &["monday"]).validate().is_err());
        assert!(schedule("07:00", &[]).validate().is_err()); // no days, no date
        let mut oneshot = schedule("07:00", &[]);
        oneshot.on = Some("2026-03-08".into());
        assert!(oneshot.validate().is_ok());
        oneshot.on = Some("03/08/2026".into());
        assert!(oneshot.validate().is_err());
    }

    #[test]
    fn validate_lowercases_days() {
        let mut s = schedule("07:00", &["Mon", "TUE"]);
        s.validate().unwrap();
        assert_eq!(s.days, vec!["mon", "tue"]);
    }

    #[test]
    fn parse_at_accepts_solar_literals() {
        assert_eq!(parse_at("sunrise"), Ok(At::Sunrise));
        assert_eq!(parse_at("sunset"), Ok(At::Sunset));
        assert!(parse_at("sundown").is_err());
        assert!(parse_at("sunset+01:00").is_err()); // offsets aren't a thing
        let mut s = schedule("Sunset", &["mon"]);
        s.validate().unwrap(); // canonicalized...
        assert_eq!(s.at, "sunset"); // ...to lowercase
    }

    const INSTANT: Duration = Duration::ZERO;
    const HOUR: Duration = Duration::from_secs(3600);

    #[test]
    fn due_matches_time_and_day() {
        // 2026-07-30 is a Thursday.
        let now = Local.with_ymd_and_hms(2026, 7, 30, 7, 0, 12).unwrap();
        assert!(schedule("07:00", &["thu"]).is_due(&now, None, INSTANT));
        assert!(!schedule("07:00", &["fri"]).is_due(&now, None, INSTANT));
        assert!(!schedule("07:01", &["thu"]).is_due(&now, None, INSTANT));
        let mut oneshot = schedule("07:00", &[]);
        oneshot.on = Some("2026-07-30".into());
        assert!(oneshot.is_due(&now, None, INSTANT));
        oneshot.on = Some("2026-07-31".into());
        assert!(!oneshot.is_due(&now, None, INSTANT));
    }

    #[test]
    fn due_lasts_for_the_scene_duration() {
        let s = schedule("07:00", &["thu"]);
        let at = |h, m| Local.with_ymd_and_hms(2026, 7, 30, h, m, 0).unwrap();
        assert!(!s.is_due(&at(6, 59), None, HOUR));
        assert!(s.is_due(&at(7, 0), None, HOUR));
        assert!(s.is_due(&at(7, 45), None, HOUR));
        assert!(!s.is_due(&at(8, 0), None, HOUR));
        // An instant scene keeps a one-minute window.
        assert!(s.is_due(&at(7, 0), None, INSTANT));
        assert!(!s.is_due(&at(7, 1), None, INSTANT));
    }

    #[test]
    fn one_shot_expires_when_its_window_closes() {
        let mut oneshot = schedule("07:00", &[]);
        oneshot.on = Some("2026-07-30".into());
        let at = |d, h, m| Local.with_ymd_and_hms(2026, 7, d, h, m, 0).unwrap();
        assert!(!oneshot.is_expired(&at(29, 12, 0), None, HOUR));
        assert!(!oneshot.is_expired(&at(30, 7, 30), None, HOUR));
        assert!(oneshot.is_expired(&at(30, 8, 0), None, HOUR));
        assert!(oneshot.is_expired(&at(31, 0, 0), None, HOUR));
        assert!(!schedule("07:00", &["thu"]).is_expired(&at(31, 0, 0), None, HOUR));
    }

    #[test]
    fn solar_without_location_is_dormant() {
        // The sun math itself is the crate's business; ours is only that a
        // solar schedule with no location never wrongly fires.
        let now = Local.with_ymd_and_hms(2026, 7, 30, 20, 15, 0).unwrap();
        assert!(!schedule("sunset", &["thu"]).is_due(&now, None, HOUR));
        assert!(!schedule("sunrise", &["thu"]).is_due(&now, None, HOUR));
    }

    fn scene(duration: f64) -> Scene {
        let point = crate::scenes::Point { t: 0.0, hue: 0.1, saturation: 0.5, level: 1.0 };
        Scene { duration, lights: BTreeMap::from([("1".to_string(), vec![point])]) }
    }

    #[test]
    fn fired_log_tracks_day_and_version() {
        let now = Local.with_ymd_and_hms(2026, 7, 30, 7, 0, 0).unwrap();
        let tomorrow = Local.with_ymd_and_hms(2026, 7, 31, 7, 0, 0).unwrap();
        let s = schedule("07:00", &["thu", "fri"]);
        let curve = scene(3600.0);
        let mut fired = FiredLog::new();
        assert!(!fired.contains("wake", &s, Some(&curve), &now));
        fired.record("wake", &s, Some(&curve), &now);
        assert!(fired.contains("wake", &s, Some(&curve), &now));
        assert!(!fired.contains("wake", &s, Some(&curve), &tomorrow));
        let edited = schedule("07:05", &["thu", "fri"]);
        assert!(!fired.contains("wake", &edited, Some(&curve), &now));
        let edited_scene = scene(1800.0);
        assert!(!fired.contains("wake", &s, Some(&edited_scene), &now));
        assert_eq!(fired.fingerprint_of("wake"), Some(fingerprint(&s, Some(&curve)).as_str()));
    }

    #[test]
    fn live_fingerprint_ignores_disabled_and_missing() {
        let s = schedule("07:00", &["thu"]);
        let curve = scene(3600.0);
        assert_eq!(live_fingerprint(Some(&s), Some(&curve)), Some(fingerprint(&s, Some(&curve))));
        let mut disabled = s.clone();
        disabled.enabled = false;
        assert_eq!(live_fingerprint(Some(&disabled), Some(&curve)), None);
        assert_eq!(live_fingerprint(None, Some(&curve)), None);
    }
}
