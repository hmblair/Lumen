//! Schedules: run a scene at a time of day, on chosen weekdays or once on a
//! date. Orthogonal to what the scene is — a schedule only references one by
//! name.
//!
//! The loop ticks every 30 s and fires each due schedule at most once per
//! day (the fired set clears at midnight, mirroring huectl's scheduler).
//! One-shot schedules delete themselves after firing.
//!
//! Author: Hamish M. Blair <hmblair@stanford.edu>

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Datelike, Local, NaiveDate, Timelike};
use serde::{Deserialize, Serialize};
use tracing::{info, warn};

use crate::runner::SceneRunner;
use crate::scenes::Scene;
use crate::store::Store;

const TICK: Duration = Duration::from_secs(30);
const DAY_NAMES: [&str; 7] = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];

fn default_true() -> bool {
    true
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(deny_unknown_fields)]
pub struct Schedule {
    /// Time of day, "HH:MM", in the box's local timezone.
    pub at: String,
    /// Weekdays to fire on: ["mon", ..., "sun"]. Ignored when `on` is set.
    #[serde(default)]
    pub days: Vec<String>,
    /// One-shot date "YYYY-MM-DD"; the schedule deletes itself after firing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on: Option<String>,
    /// Name of the scene to run. The scene carries everything about *what*
    /// happens, including which lights; a schedule is time-only.
    pub scene: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

impl Schedule {
    /// Validate and canonicalize (lowercases day names). The scene reference
    /// is checked by the API layer against the scene store.
    pub fn validate(&mut self) -> Result<(), String> {
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

    fn is_due(&self, now: &DateTime<Local>) -> bool {
        let Ok((hour, minute)) = parse_at(&self.at) else {
            return false;
        };
        if now.hour() != hour || now.minute() != minute {
            return false;
        }
        match &self.on {
            Some(date) => {
                NaiveDate::parse_from_str(date, "%Y-%m-%d").ok() == Some(now.date_naive())
            }
            None => {
                let today = DAY_NAMES[now.weekday().num_days_from_monday() as usize];
                self.days.iter().any(|d| d == today)
            }
        }
    }
}

fn parse_at(at: &str) -> Result<(u32, u32), String> {
    let err = || format!("invalid time '{at}' (use HH:MM)");
    let (h, m) = at.split_once(':').ok_or_else(err)?;
    let hour: u32 = h.parse().map_err(|_| err())?;
    let minute: u32 = m.parse().map_err(|_| err())?;
    if hour > 23 || minute > 59 {
        return Err(err());
    }
    Ok((hour, minute))
}

pub fn spawn_scheduler(
    schedules: Arc<Store<Schedule>>,
    scenes: Arc<Store<Scene>>,
    runner: Arc<SceneRunner>,
) {
    tokio::spawn(async move {
        let mut fired: HashSet<String> = HashSet::new();
        let mut last_date = None;
        // The fired set is in-memory, so a restart inside the minute a
        // schedule already fired would re-fire it. Pre-mark anything due in
        // the startup minute; the cost — skipping a fire scheduled for the
        // exact minute of a (seconds-long) deploy restart — is negligible.
        let startup = Local::now();
        for (name, schedule) in schedules.map().await {
            if schedule.enabled && schedule.is_due(&startup) {
                fired.insert(format!("{name}@{}", startup.date_naive()));
            }
        }
        loop {
            let now = Local::now();
            if last_date != Some(now.date_naive()) {
                fired.clear();
                last_date = Some(now.date_naive());
            }

            for (name, schedule) in schedules.map().await {
                // One-shots whose date passed unfired (e.g. the daemon was
                // down that day) would otherwise linger forever.
                if let Some(on) = &schedule.on {
                    if let Ok(date) = NaiveDate::parse_from_str(on, "%Y-%m-%d") {
                        if date < now.date_naive() {
                            warn!("Schedule '{name}' expired unfired ({on}); removing");
                            schedules.remove(&name).await;
                            continue;
                        }
                    }
                }
                let key = format!("{name}@{}", now.date_naive());
                if !schedule.enabled || fired.contains(&key) || !schedule.is_due(&now) {
                    continue;
                }
                fired.insert(key);
                match scenes.get(&schedule.scene).await {
                    Some(scene) => {
                        info!("Schedule '{name}' firing scene '{}'", schedule.scene);
                        if let Err(running) =
                            runner.run(&schedule.scene, scene, Some(name.clone())).await
                        {
                            warn!("Schedule '{name}' skipped: scene '{running}' is still running");
                        }
                    }
                    None => warn!("Schedule '{name}' references missing scene '{}'", schedule.scene),
                }
                if schedule.on.is_some() {
                    schedules.remove(&name).await;
                }
            }

            tokio::time::sleep(TICK).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn due_matches_time_and_day() {
        use chrono::TimeZone;
        // 2026-07-30 is a Thursday.
        let now = Local.with_ymd_and_hms(2026, 7, 30, 7, 0, 12).unwrap();
        assert!(schedule("07:00", &["thu"]).is_due(&now));
        assert!(!schedule("07:00", &["fri"]).is_due(&now));
        assert!(!schedule("07:01", &["thu"]).is_due(&now));
        let mut oneshot = schedule("07:00", &[]);
        oneshot.on = Some("2026-07-30".into());
        assert!(oneshot.is_due(&now));
        oneshot.on = Some("2026-07-31".into());
        assert!(!oneshot.is_due(&now));
    }
}
