//! Polled bridge state, cached and shared by every HTTP client.
//!
//! A background task polls the bridge once a second so any number of clients
//! can read light state without multiplying bridge traffic. Writes go through
//! to the bridge synchronously and patch the cache optimistically, so a read
//! that follows a write reflects it immediately instead of waiting for the
//! next poll.
//!
//! Author: Hamish M. Blair <hmblair@stanford.edu>

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::{Mutex, RwLock};
use tracing::{info, warn};

use crate::bridge::{Bridge, BridgeError, Light, StateUpdate};

const POLL_INTERVAL: Duration = Duration::from_secs(1);
const FRESH_FOR: Duration = Duration::from_secs(5);
/// After an API write to a light, bridge polls don't overwrite it for this
/// long — the bridge can serve a snapshot from just before the write, and
/// letting that clobber the cache would briefly revert accepted writes for
/// every client. Makes /lights monotone w.r.t. acknowledged writes.
const WRITE_GUARD: Duration = Duration::from_secs(2);

pub struct LightCache {
    bridge: Arc<Bridge>,
    inner: RwLock<Option<(Vec<Light>, Instant)>>,
    /// Per-light time of the last accepted API write.
    written: Mutex<HashMap<String, Instant>>,
}

impl LightCache {
    pub fn new(bridge: Arc<Bridge>) -> Self {
        LightCache {
            bridge,
            inner: RwLock::new(None),
            written: Mutex::new(HashMap::new()),
        }
    }

    /// Current lights, or None when the bridge data is stale/absent.
    pub async fn snapshot(&self) -> Option<Vec<Light>> {
        let guard = self.inner.read().await;
        let (lights, updated_at) = guard.as_ref()?;
        if updated_at.elapsed() > FRESH_FOR {
            return None;
        }
        Some(lights.clone())
    }

    /// Write through to the bridge, then patch the cached light.
    pub async fn apply(&self, light_id: &str, state: &StateUpdate) -> Result<(), BridgeError> {
        self.bridge.apply_state(light_id, state).await?;
        {
            let mut guard = self.inner.write().await;
            if let Some((lights, _)) = guard.as_mut() {
                if let Some(light) = lights.iter_mut().find(|l| l.id == light_id) {
                    if let Some(on) = state.on {
                        light.on = on;
                    }
                    if let Some(hue) = state.hue {
                        light.hue = hue;
                    }
                    if let Some(saturation) = state.saturation {
                        light.saturation = saturation;
                    }
                    if let Some(level) = state.level {
                        light.level = level;
                    }
                }
            }
        }
        self.written.lock().await.insert(light_id.to_string(), Instant::now());
        Ok(())
    }

    /// Apply one update to several lights (all cached lights when `targets`
    /// is empty). Used by effects; per-light failures are logged and skipped
    /// so one unreachable lamp doesn't stall a running effect.
    pub async fn apply_many(&self, targets: &[String], state: &StateUpdate) {
        let ids: Vec<String> = if targets.is_empty() {
            match self.snapshot().await {
                Some(lights) => lights.iter().map(|l| l.id.clone()).collect(),
                None => return,
            }
        } else {
            targets.to_vec()
        };
        for id in ids {
            if let Err(e) = self.apply(&id, state).await {
                warn!("Effect write to light {id} failed: {e}");
            }
        }
    }

    /// Poll forever; logs only reachability transitions, not every failure.
    pub fn spawn_poll_loop(self: &Arc<Self>) {
        let cache = Arc::clone(self);
        tokio::spawn(async move {
            let mut was_reachable: Option<bool> = None;
            loop {
                match cache.bridge.fetch_lights().await {
                    Ok(lights) => {
                        if was_reachable != Some(true) {
                            info!("Bridge reachable; {} light(s)", lights.len());
                            was_reachable = Some(true);
                        }
                        // Recently written lights keep their cached (written)
                        // state; the bridge's view may predate the write.
                        let mut written = cache.written.lock().await;
                        written.retain(|_, at| at.elapsed() < WRITE_GUARD);
                        let mut guard = cache.inner.write().await;
                        let merged: Vec<Light> = lights
                            .into_iter()
                            .map(|fresh| {
                                if written.contains_key(&fresh.id) {
                                    if let Some((cached, _)) = guard.as_ref() {
                                        if let Some(local) =
                                            cached.iter().find(|l| l.id == fresh.id)
                                        {
                                            return local.clone();
                                        }
                                    }
                                }
                                fresh
                            })
                            .collect();
                        *guard = Some((merged, Instant::now()));
                    }
                    Err(e) => {
                        if was_reachable != Some(false) {
                            warn!("Bridge unreachable: {e}");
                            was_reachable = Some(false);
                        }
                    }
                }
                tokio::time::sleep(POLL_INTERVAL).await;
            }
        });
    }
}
