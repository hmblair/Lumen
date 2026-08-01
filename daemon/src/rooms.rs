//! Daemon-authoritative rooms.
//!
//! The daemon — not the bridge — is the source of truth for rooms: they
//! live in rooms.json with daemon-generated ids, may be empty, and survive
//! anything the bridge does. Each room with at least one light is mirrored
//! to a bridge LightGroup purely as a convenience for the vendor ecosystem
//! (the Hue app shows the same rooms); the bridge refuses empty groups, so
//! an emptied room simply loses its mirror until a light returns. Mirroring
//! is best-effort: failures are logged, never surfaced — room operations
//! cannot fail because of the bridge.
//!
//! On first run (no rooms.json), existing bridge groups are imported once,
//! adopting their membership and keeping them as mirrors.
//!
//! Author: Hamish M. Blair <hmblair@stanford.edu>

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tracing::{info, warn};

use crate::bridge::Bridge;
use crate::store::Store;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Room {
    pub name: String,
    #[serde(default)]
    pub lights: Vec<String>,
    /// The bridge group mirroring this room, when it has lights. Internal
    /// bookkeeping — the API never exposes it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bridge_id: Option<String>,
}

pub struct Rooms {
    store: Store<Room>,
    bridge: Arc<Bridge>,
}

impl Rooms {
    pub fn new(store: Store<Room>, bridge: Arc<Bridge>) -> Self {
        Rooms { store, bridge }
    }

    pub async fn map(&self) -> BTreeMap<String, Room> {
        self.store.map().await
    }

    pub async fn get(&self, id: &str) -> Option<Room> {
        self.store.get(id).await
    }

    /// Create a room (empty is fine); returns its id.
    pub async fn create(&self, name: &str, lights: Vec<String>) -> String {
        let id = new_id();
        self.store
            .upsert(id.clone(), Room { name: name.to_string(), lights, bridge_id: None })
            .await;
        self.mirror(&id).await;
        id
    }

    /// Update a room's name and/or membership (nil = leave unchanged).
    pub async fn update(&self, id: &str, name: Option<&str>, lights: Option<Vec<String>>) {
        let Some(mut room) = self.store.get(id).await else { return };
        if let Some(name) = name {
            room.name = name.to_string();
        }
        if let Some(lights) = lights {
            room.lights = lights;
        }
        self.store.upsert(id.to_string(), room).await;
        self.mirror(id).await;
    }

    /// Delete a room (its mirror too, best-effort).
    pub async fn delete(&self, id: &str) {
        if let Some(room) = self.store.get(id).await {
            if let Some(bridge_id) = &room.bridge_id {
                if let Err(e) = self.bridge.delete_group(bridge_id).await {
                    warn!("Mirror cleanup for deleted room '{}' failed: {e}", room.name);
                }
            }
        }
        self.store.remove(id).await;
    }

    /// Bring the room's bridge mirror in line: rooms with lights get a
    /// group (created or updated), emptied rooms lose theirs. Best-effort —
    /// the store was already updated and is the truth.
    async fn mirror(&self, id: &str) {
        let Some(mut room) = self.store.get(id).await else { return };
        match (room.bridge_id.clone(), room.lights.is_empty()) {
            (None, true) => {}
            (Some(bridge_id), true) => {
                if let Err(e) = self.bridge.delete_group(&bridge_id).await {
                    warn!("Dropping mirror of emptied room '{}' failed: {e}", room.name);
                }
                room.bridge_id = None;
                self.store.upsert(id.to_string(), room).await;
            }
            (None, false) => match self.bridge.create_group(&room.name, &room.lights).await {
                Ok(bridge_id) => {
                    room.bridge_id = Some(bridge_id);
                    self.store.upsert(id.to_string(), room).await;
                }
                Err(e) => warn!("Mirroring room '{}' to the bridge failed: {e}", room.name),
            },
            (Some(bridge_id), false) => {
                if let Err(e) = self
                    .bridge
                    .update_group(&bridge_id, Some(&room.name), Some(&room.lights))
                    .await
                {
                    // The mirror may have vanished (e.g. deleted in the
                    // vendor app); recreate it.
                    warn!("Updating mirror of room '{}' failed ({e}); recreating", room.name);
                    match self.bridge.create_group(&room.name, &room.lights).await {
                        Ok(new_id) => {
                            room.bridge_id = Some(new_id);
                            self.store.upsert(id.to_string(), room).await;
                        }
                        Err(e) => warn!("Recreating mirror of room '{}' failed: {e}", room.name),
                    }
                }
            }
        }
    }
}

/// Daemon-generated room id — stable across bridge group churn.
fn new_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock after epoch")
        .as_nanos();
    format!("r{nanos:x}")
}

/// One-time import: on a fresh install (rooms.json absent), adopt the
/// bridge's existing groups as rooms, keeping them as mirrors. Waits for
/// the bridge like the preset seeder.
pub fn spawn_bridge_import(rooms: Arc<Rooms>, should_import: bool) {
    if !should_import {
        return;
    }
    tokio::spawn(async move {
        loop {
            match rooms.bridge.fetch_groups().await {
                Ok(groups) => {
                    for group in groups {
                        let id = new_id();
                        rooms
                            .store
                            .upsert(id, Room {
                                name: group.name.clone(),
                                lights: group.lights,
                                bridge_id: Some(group.id),
                            })
                            .await;
                        info!("Imported bridge group '{}' as a room", group.name);
                    }
                    return;
                }
                Err(_) => tokio::time::sleep(Duration::from_secs(1)).await,
            }
        }
    });
}
