//! A tiny JSON-file-backed named-item store, used for scenes and schedules.
//!
//! Items live in a BTreeMap (stable on-disk ordering) keyed by name and are
//! persisted as pretty-printed JSON on every mutation — the write volume is
//! human-scale, so simplicity beats cleverness.
//!
//! Author: Hamish M. Blair <hmblair@stanford.edu>

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::de::DeserializeOwned;
use serde::Serialize;
use tokio::sync::Mutex;
use tracing::{error, warn};

pub struct Store<T> {
    path: PathBuf,
    items: Mutex<BTreeMap<String, T>>,
}

impl<T: Clone + Serialize + DeserializeOwned> Store<T> {
    /// Load from `path`. A missing file yields `seed` (persisted immediately
    /// so the file is visible and editable); a corrupt file is treated as
    /// empty rather than crashing the daemon, with the error logged.
    pub fn load(path: PathBuf, seed: BTreeMap<String, T>) -> Self {
        let items = match std::fs::read_to_string(&path) {
            Ok(text) => match serde_json::from_str(&text) {
                Ok(map) => map,
                Err(e) => {
                    error!("Failed to parse {}: {e}; starting empty", path.display());
                    BTreeMap::new()
                }
            },
            Err(_) => {
                let store = Store { path: path.clone(), items: Mutex::new(seed) };
                store.save_blocking();
                return store;
            }
        };
        Store { path, items: Mutex::new(items) }
    }

    pub async fn map(&self) -> BTreeMap<String, T> {
        self.items.lock().await.clone()
    }

    pub async fn get(&self, name: &str) -> Option<T> {
        self.items.lock().await.get(name).cloned()
    }

    pub async fn upsert(&self, name: String, item: T) {
        let mut items = self.items.lock().await;
        items.insert(name, item);
        self.save(&items);
    }

    /// Returns false if the name wasn't present.
    pub async fn remove(&self, name: &str) -> bool {
        let mut items = self.items.lock().await;
        let removed = items.remove(name).is_some();
        if removed {
            self.save(&items);
        }
        removed
    }

    fn save(&self, items: &BTreeMap<String, T>) {
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let json = serde_json::to_string_pretty(items).expect("serializable store") + "\n";
        if let Err(e) = std::fs::write(&self.path, json) {
            warn!("Failed to save {}: {e}", self.path.display());
        }
    }

    fn save_blocking(&self) {
        // Only called from load(), before the store is shared.
        let items = self.items.try_lock().expect("unshared at load");
        self.save(&items);
    }
}
