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

use crate::bridge::{Bridge, BridgeError, Group, Light, StateUpdate};

const POLL_INTERVAL: Duration = Duration::from_secs(1);
const FRESH_FOR: Duration = Duration::from_secs(5);
/// After an API write to a light, bridge polls don't overwrite it for this
/// long — the bridge can serve a snapshot from just before the write, and
/// letting that clobber the cache would briefly revert accepted writes for
/// every client. Makes /lights monotone w.r.t. acknowledged writes.
const WRITE_GUARD: Duration = Duration::from_secs(2);
/// Groups change rarely (and our own CRUD refreshes eagerly), so they piggy-
/// back on every Nth light poll.
const GROUP_POLL_EVERY: u64 = 10;

pub struct LightCache {
    bridge: Arc<Bridge>,
    inner: RwLock<Option<(Vec<Light>, Instant)>>,
    groups: RwLock<Vec<Group>>,
    /// Per-light time of the last accepted API write.
    written: Mutex<HashMap<String, Instant>>,
}

impl LightCache {
    pub fn new(bridge: Arc<Bridge>) -> Self {
        LightCache {
            bridge,
            inner: RwLock::new(None),
            groups: RwLock::new(Vec::new()),
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

    /// Current groups; None while the bridge is unreachable (same freshness
    /// gate as the lights).
    pub async fn groups(&self) -> Option<Vec<Group>> {
        self.snapshot().await?;
        Some(self.groups.read().await.clone())
    }

    /// Write one state atomically to every member of a group (a single
    /// bridge command — the lights change in lockstep), patching the cache
    /// and write guard for each member.
    pub async fn apply_group(&self, group_id: &str, state: &StateUpdate) -> Result<(), BridgeError> {
        let members: Vec<String> = self
            .groups
            .read()
            .await
            .iter()
            .find(|g| g.id == group_id)
            .map(|g| g.lights.clone())
            .unwrap_or_default();
        self.bridge.apply_state_to_group(group_id, state).await?;
        {
            let mut guard = self.inner.write().await;
            if let Some((lights, _)) = guard.as_mut() {
                for light in lights.iter_mut().filter(|l| members.contains(&l.id)) {
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
        let now = Instant::now();
        let mut written = self.written.lock().await;
        for id in members {
            written.insert(id, now);
        }
        Ok(())
    }

    /// Re-fetch groups from the bridge (used after CRUD, so clients see the
    /// change immediately rather than at the next periodic refresh).
    pub async fn refresh_groups(&self) -> Result<(), BridgeError> {
        let groups = self.bridge.fetch_groups().await?;
        *self.groups.write().await = groups;
        Ok(())
    }

    pub async fn create_group(&self, name: &str, lights: &[String]) -> Result<String, BridgeError> {
        let id = self.bridge.create_group(name, lights).await?;
        self.refresh_groups().await?;
        Ok(id)
    }

    pub async fn update_group(
        &self,
        group_id: &str,
        name: Option<&str>,
        lights: Option<&[String]>,
    ) -> Result<(), BridgeError> {
        self.bridge.update_group(group_id, name, lights).await?;
        self.refresh_groups().await
    }

    pub async fn delete_group(&self, group_id: &str) -> Result<(), BridgeError> {
        self.bridge.delete_group(group_id).await?;
        self.refresh_groups().await
    }

    /// Rename a light on the bridge, patching the cache like a state write.
    pub async fn rename(&self, light_id: &str, name: &str) -> Result<(), BridgeError> {
        self.bridge.rename_light(light_id, name).await?;
        {
            let mut guard = self.inner.write().await;
            if let Some((lights, _)) = guard.as_mut() {
                if let Some(light) = lights.iter_mut().find(|l| l.id == light_id) {
                    light.name = name.to_string();
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
            let mut cycle: u64 = 0;
            loop {
                if cycle % GROUP_POLL_EVERY == 0 {
                    if let Ok(groups) = cache.bridge.fetch_groups().await {
                        *cache.groups.write().await = groups;
                    }
                }
                cycle += 1;
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
