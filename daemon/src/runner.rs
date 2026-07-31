//! Runs one scene at a time and tracks which lights it owns.
//!
//! Starting a scene cancels any running one (latest intent wins). While a
//! scene runs it owns its target lights — the API layer rejects manual
//! writes to them (schedule-wins arbitration) and reports the run via
//! /status. Ownership is emergent from duration: an instant scene finishes
//! (and releases) as soon as its single write lands.
//!
//! Author: Hamish M. Blair <hmblair@stanford.edu>

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use chrono::{DateTime, Local, SecondsFormat};
use serde::{Serialize, Serializer};
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;
use tracing::info;

use crate::cache::LightCache;
use crate::scenes::Scene;

/// Seconds-precision RFC 3339, so Foundation's ISO8601 decoder (which
/// rejects fractional seconds by default) parses it directly.
fn rfc3339_secs<S: Serializer>(dt: &DateTime<Local>, s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str(&dt.to_rfc3339_opts(SecondsFormat::Secs, true))
}

/// What /status reports while a scene runs.
#[derive(Serialize, Clone)]
pub struct RunningInfo {
    pub scene: String,
    /// The schedule that fired it, absent for manual runs.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub schedule: Option<String>,
    /// Owned lights; empty = all lights.
    pub targets: Vec<String>,
    #[serde(serialize_with = "rfc3339_secs")]
    pub started: DateTime<Local>,
    #[serde(serialize_with = "rfc3339_secs")]
    pub ends: DateTime<Local>,
}

struct Current {
    info: RunningInfo,
    cancel: CancellationToken,
    generation: u64,
}

pub struct SceneRunner {
    cache: Arc<LightCache>,
    current: Mutex<Option<Current>>,
    generation: AtomicU64,
}

impl SceneRunner {
    pub fn new(cache: Arc<LightCache>) -> Self {
        SceneRunner {
            cache,
            current: Mutex::new(None),
            generation: AtomicU64::new(0),
        }
    }

    /// Start `scene`. A running scene blocks new runs (schedule-wins,
    /// uniformly: manual light writes and scene starts both defer to it) —
    /// the Err carries the running scene's name. The scene itself says which
    /// lights it touches; those are what it owns.
    pub async fn run(
        self: &Arc<Self>,
        name: &str,
        scene: Scene,
        schedule: Option<String>,
    ) -> Result<(), String> {
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let cancel = CancellationToken::new();
        let started = Local::now();
        let ends = started
            + chrono::Duration::from_std(scene.duration()).unwrap_or_else(|_| chrono::Duration::zero());
        let info = RunningInfo {
            scene: name.to_string(),
            schedule,
            targets: scene.light_ids(),
            started,
            ends,
        };

        {
            let mut current = self.current.lock().await;
            if let Some(running) = current.as_ref() {
                return Err(running.info.scene.clone());
            }
            *current = Some(Current { info, cancel: cancel.clone(), generation });
        }

        info!("Running scene '{name}'");
        let runner = Arc::clone(self);
        let cache = Arc::clone(&self.cache);
        tokio::spawn(async move {
            scene.run(cache, cancel).await;
            // Release ownership — unless a newer run already replaced us.
            let mut current = runner.current.lock().await;
            if current.as_ref().map(|c| c.generation) == Some(generation) {
                *current = None;
            }
        });
        Ok(())
    }

    /// Stop the running scene, returning its name.
    pub async fn stop(&self) -> Option<String> {
        let mut current = self.current.lock().await;
        current.take().map(|c| {
            c.cancel.cancel();
            info!("Stopped scene '{}'", c.info.scene);
            c.info.scene
        })
    }

    pub async fn status(&self) -> Option<RunningInfo> {
        self.current.lock().await.as_ref().map(|c| c.info.clone())
    }

    /// The name of the scene owning this light, if any.
    pub async fn owner_of(&self, light_id: &str) -> Option<String> {
        let current = self.current.lock().await;
        let c = current.as_ref()?;
        let owns = c.info.targets.iter().any(|t| t == light_id);
        owns.then(|| c.info.scene.clone())
    }
}
