//! Philips Hue provider: bridge client plus unit normalization.
//!
//! The provider seam, mirroring the Python daemon's bridge.py: everything
//! Hue-specific — the wire protocol, JSON shape, 0-65535 hue / 1-254 sat+bri
//! encodings, mDNS discovery — lives here. The rest of the daemon (and every
//! client of its HTTP API) sees only normalized lights with
//! hue/saturation/level in 0...1. Supporting another vendor means rewriting
//! this one module.
//!
//! Author: Hamish M. Blair <hmblair@stanford.edu>

use std::fmt;
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::{json, Map, Value};
use tokio::sync::Mutex;
use tracing::{info, warn};

use crate::config::{self, Config};

const MDNS_SERVICE: &str = "_hue._tcp.local.";
const DISCOVERY_TIMEOUT: Duration = Duration::from_secs(3);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug)]
pub struct BridgeError(pub String);

impl fmt::Display for BridgeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// A light in the normalized schema clients see (all values 0...1).
#[derive(Serialize, Clone)]
pub struct Light {
    pub id: String,
    pub name: String,
    pub on: bool,
    pub hue: f64,
    pub saturation: f64,
    pub level: f64,
    pub reachable: bool,
}

/// A light group in the normalized schema. Groups live on the bridge (like
/// names), so the vendor ecosystem sees the same membership; Lumen creates
/// them as type LightGroup, which allows arbitrary overlapping membership
/// (unlike the vendor app's one-Room-per-light).
#[derive(Serialize, Clone, Debug)]
pub struct Group {
    pub id: String,
    pub name: String,
    pub lights: Vec<String>,
}

/// A normalized partial state update (any subset of the four keys).
/// `transition` (seconds) asks the light to fade to the target rather than
/// jump; it's used by effects internally and not exposed over the HTTP API.
#[derive(Default, Clone)]
pub struct StateUpdate {
    pub on: Option<bool>,
    pub hue: Option<f64>,
    pub saturation: Option<f64>,
    pub level: Option<f64>,
    pub transition: Option<f64>,
}

/// The bridge addressing state: `configured` is the explicit override from
/// config.env (None = auto-discover via mDNS); `active` is the address
/// currently in use (discovered or configured).
struct IpState {
    configured: Option<String>,
    active: Option<String>,
}

pub struct Bridge {
    api_key: String,
    client: reqwest::Client,
    /// Also serializes discovery, like the Python lock.
    state: Mutex<IpState>,
}

impl Bridge {
    pub fn new(config: Config) -> Self {
        // The bridge serves a self-signed cert on the LAN; verification is off
        // for that hop only (clients reach the daemon via Caddy's real TLS).
        let client = reqwest::Client::builder()
            .danger_accept_invalid_certs(true)
            .timeout(REQUEST_TIMEOUT)
            .build()
            .expect("reqwest client");
        Bridge {
            api_key: config.api_key,
            client,
            state: Mutex::new(IpState { configured: config.bridge_ip, active: None }),
        }
    }

    /// (configured override, address currently in use).
    pub async fn ip_state(&self) -> (Option<String>, Option<String>) {
        let state = self.state.lock().await;
        (state.configured.clone(), state.active.clone())
    }

    /// Change the configured bridge address. Some(ip) is probed before being
    /// committed (a typo shouldn't strand the daemon); None returns to mDNS
    /// auto-discovery. Persisted to config.env on success.
    pub async fn set_configured_ip(&self, ip: Option<String>) -> Result<(), BridgeError> {
        if let Some(ip) = &ip {
            let url = format!("https://{ip}/api/{}/lights", self.api_key);
            self.client
                .get(&url)
                .send()
                .await
                .and_then(|r| r.error_for_status())
                // The reqwest error's Display includes the full URL — and with
                // it the API key — so don't echo it to clients.
                .map_err(|_| BridgeError(format!("no Hue bridge answered at {ip}")))?;
        }
        let mut state = self.state.lock().await;
        state.configured = ip.clone();
        // None clears the active address too, forcing rediscovery next use.
        state.active = ip.clone();
        config::persist_bridge_ip(ip.as_deref());
        info!("Bridge address set to {}", ip.as_deref().unwrap_or("auto (mDNS)"));
        Ok(())
    }

    /// All lights in normalized form. Errors when the bridge is unreachable.
    pub async fn fetch_lights(&self) -> Result<Vec<Light>, BridgeError> {
        let response = self.request(reqwest::Method::GET, "/lights", None).await?;
        let raw: Value = response
            .json()
            .await
            .map_err(|e| BridgeError(format!("bridge unreachable: {e}")))?;
        let Value::Object(map) = raw else {
            return Err(BridgeError("unexpected /lights response".into()));
        };
        Ok(map
            .iter()
            .filter_map(|(id, value)| value.as_object().map(|raw| normalize(id, raw)))
            .collect())
    }

    /// Apply a normalized partial state to one light.
    pub async fn apply_state(&self, light_id: &str, state: &StateUpdate) -> Result<(), BridgeError> {
        let path = format!("/lights/{light_id}/state");
        let response = self
            .request(reqwest::Method::PUT, &path, Some(denormalize(state)))
            .await
            .map_err(|e| BridgeError(format!("write to light {light_id} failed: {e}")))?;
        confirm_write(response, &format!("write to light {light_id} failed")).await
    }

    /// Rename a light. Names live on the light resource (not /state) and are
    /// stored by the bridge itself, so every client — including the vendor's
    /// own app — sees the same name.
    pub async fn rename_light(&self, light_id: &str, name: &str) -> Result<(), BridgeError> {
        let path = format!("/lights/{light_id}");
        let response = self
            .request(reqwest::Method::PUT, &path, Some(json!({ "name": name })))
            .await
            .map_err(|e| BridgeError(format!("rename of light {light_id} failed: {e}")))?;
        confirm_write(response, &format!("rename of light {light_id} failed")).await
    }

    // MARK: groups

    /// All groups in normalized form.
    pub async fn fetch_groups(&self) -> Result<Vec<Group>, BridgeError> {
        let raw: Value = self
            .request(reqwest::Method::GET, "/groups", None)
            .await
            .map_err(|e| BridgeError(format!("bridge unreachable: {e}")))?
            .json()
            .await
            .map_err(|e| BridgeError(format!("bridge unreachable: {e}")))?;
        let Value::Object(map) = raw else {
            return Err(BridgeError("unexpected /groups response".into()));
        };
        Ok(map
            .iter()
            .filter_map(|(id, value)| {
                let name = value.get("name")?.as_str()?.to_string();
                let lights = value
                    .get("lights")?
                    .as_array()?
                    .iter()
                    .filter_map(|l| l.as_str().map(str::to_string))
                    .collect();
                Some(Group { id: id.clone(), name, lights })
            })
            .collect())
    }

    /// Apply a normalized partial state to every member of a group with one
    /// bridge command — atomic, so the lights change in lockstep.
    pub async fn apply_state_to_group(&self, group_id: &str, state: &StateUpdate) -> Result<(), BridgeError> {
        let path = format!("/groups/{group_id}/action");
        let response = self
            .request(reqwest::Method::PUT, &path, Some(denormalize(state)))
            .await
            .map_err(|e| BridgeError(format!("write to group {group_id} failed: {e}")))?;
        confirm_write(response, &format!("write to group {group_id} failed")).await
    }

    /// Create a group; returns the bridge-assigned id. The v1 API reports
    /// failures inside a 200 body, so the response is checked, not just the
    /// status.
    pub async fn create_group(&self, name: &str, lights: &[String]) -> Result<String, BridgeError> {
        let body = json!({ "name": name, "lights": lights, "type": "LightGroup" });
        let response: Value = self
            .request(reqwest::Method::POST, "/groups", Some(body))
            .await
            .map_err(|e| BridgeError(format!("group creation failed: {e}")))?
            .json()
            .await
            .map_err(|e| BridgeError(format!("group creation failed: {e}")))?;
        if let Some(message) = hue_error(&response) {
            return Err(BridgeError(format!("group creation failed: {message}")));
        }
        response
            .as_array()
            .and_then(|items| items.first())
            .and_then(|item| item.get("success"))
            .and_then(|success| success.get("id"))
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| BridgeError("group creation: unexpected response".into()))
    }

    /// Update a group's name and/or membership.
    pub async fn update_group(
        &self,
        group_id: &str,
        name: Option<&str>,
        lights: Option<&[String]>,
    ) -> Result<(), BridgeError> {
        let mut body = Map::new();
        if let Some(name) = name {
            body.insert("name".into(), json!(name));
        }
        if let Some(lights) = lights {
            body.insert("lights".into(), json!(lights));
        }
        let path = format!("/groups/{group_id}");
        let response: Value = self
            .request(reqwest::Method::PUT, &path, Some(Value::Object(body)))
            .await
            .map_err(|e| BridgeError(format!("group update failed: {e}")))?
            .json()
            .await
            .map_err(|e| BridgeError(format!("group update failed: {e}")))?;
        match hue_error(&response) {
            Some(message) => Err(BridgeError(format!("group update failed: {message}"))),
            None => Ok(()),
        }
    }

    pub async fn delete_group(&self, group_id: &str) -> Result<(), BridgeError> {
        let path = format!("/groups/{group_id}");
        let response: Value = self
            .request(reqwest::Method::DELETE, &path, None)
            .await
            .map_err(|e| BridgeError(format!("group deletion failed: {e}")))?
            .json()
            .await
            .map_err(|e| BridgeError(format!("group deletion failed: {e}")))?;
        match hue_error(&response) {
            Some(message) => Err(BridgeError(format!("group deletion failed: {message}"))),
            None => Ok(()),
        }
    }

    /// Issue a bridge request; on a connection error, rediscover and retry once.
    async fn request(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<reqwest::Response, BridgeError> {
        let ip = self.current_ip().await?;
        match self.send(&ip, method.clone(), path, body.as_ref()).await {
            Err(e) if e.is_connect() => {
                if !self.rediscover().await {
                    return Err(BridgeError(format!("bridge unreachable: {e}")));
                }
                let ip = self.current_ip().await?;
                self.send(&ip, method, path, body.as_ref())
                    .await
                    .and_then(|r| r.error_for_status())
                    .map_err(|e| BridgeError(format!("bridge unreachable: {e}")))
            }
            other => other
                .and_then(|r| r.error_for_status())
                .map_err(|e| BridgeError(format!("bridge unreachable: {e}"))),
        }
    }

    async fn send(
        &self,
        ip: &str,
        method: reqwest::Method,
        path: &str,
        body: Option<&Value>,
    ) -> Result<reqwest::Response, reqwest::Error> {
        let url = format!("https://{ip}/api/{}{path}", self.api_key);
        let mut req = self.client.request(method, &url);
        if let Some(body) = body {
            req = req.json(body);
        }
        req.send().await
    }

    /// The active bridge IP, resolving it on first use: the configured value
    /// if set, otherwise mDNS discovery.
    async fn current_ip(&self) -> Result<String, BridgeError> {
        let mut state = self.state.lock().await;
        if let Some(ip) = state.active.as_ref() {
            return Ok(ip.clone());
        }
        if let Some(ip) = state.configured.clone() {
            state.active = Some(ip.clone());
            return Ok(ip);
        }
        match discover().await {
            Some(ip) => {
                info!("Discovered Hue bridge at {ip} via mDNS");
                state.active = Some(ip.clone());
                Ok(ip)
            }
            None => Err(BridgeError(
                "no BRIDGE_IP configured and mDNS discovery failed".into(),
            )),
        }
    }

    /// Re-run mDNS and update the active IP if a different one is found.
    /// Returns true if it changed. Runs even with a configured BRIDGE_IP,
    /// matching the Python daemon: a live discovery beats a stale config
    /// value when the configured address stops answering.
    async fn rediscover(&self) -> bool {
        let mut state = self.state.lock().await;
        let prev = state.active.clone();
        match discover().await {
            Some(new_ip) if prev.as_deref() != Some(new_ip.as_str()) => {
                info!(
                    "Bridge IP changed: {} -> {new_ip}",
                    prev.as_deref().unwrap_or("none")
                );
                state.active = Some(new_ip);
                true
            }
            Some(_) => false,
            None => {
                warn!("mDNS discovery found no Hue bridge");
                false
            }
        }
    }
}

/// Find the Hue bridge on the local network via mDNS (first IPv4 wins).
async fn discover() -> Option<String> {
    tokio::task::spawn_blocking(discover_blocking).await.ok()?
}

fn discover_blocking() -> Option<String> {
    use mdns_sd::{ServiceDaemon, ServiceEvent};

    let mdns = ServiceDaemon::new().ok()?;
    let receiver = mdns.browse(MDNS_SERVICE).ok()?;
    let deadline = Instant::now() + DISCOVERY_TIMEOUT;

    let mut found = None;
    while found.is_none() {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        match receiver.recv_timeout(remaining) {
            Ok(ServiceEvent::ServiceResolved(info)) => {
                found = info
                    .get_addresses()
                    .iter()
                    .find(|a| a.is_ipv4())
                    .map(|a| a.to_string());
            }
            Ok(_) => continue,
            Err(_) => break,
        }
    }
    let _ = mdns.shutdown();
    found
}

/// Confirm a state/rename write: the v1 API reports failures inside 200
/// bodies, so a write isn't done until its body says so.
async fn confirm_write(response: reqwest::Response, context: &str) -> Result<(), BridgeError> {
    let body: Value = response
        .json()
        .await
        .map_err(|e| BridgeError(format!("{context}: {e}")))?;
    match hue_error(&body) {
        Some(message) => Err(BridgeError(format!("{context}: {message}"))),
        None => Ok(()),
    }
}

/// The Hue v1 API reports failures as `[{"error": {"description": ...}}]`
/// inside a 200 response; extract the description if present.
fn hue_error(response: &Value) -> Option<String> {
    response.as_array()?.iter().find_map(|item| {
        item.get("error")?
            .get("description")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or(Some("unknown bridge error".to_string()))
    })
}

// MARK: normalization

/// Hue-native encodings -> the normalized 0...1 schema clients see.
fn normalize(id: &str, raw: &Map<String, Value>) -> Light {
    let empty = Map::new();
    let state = raw
        .get("state")
        .and_then(Value::as_object)
        .unwrap_or(&empty);
    let num = |key: &str| state.get(key).and_then(Value::as_f64).unwrap_or(0.0);
    Light {
        id: id.to_string(),
        name: raw
            .get("name")
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or_else(|| format!("Light {id}")),
        on: state.get("on").and_then(Value::as_bool).unwrap_or(false),
        hue: num("hue") / 65_535.0,
        saturation: num("sat") / 254.0,
        level: num("bri") / 254.0,
        reachable: state
            .get("reachable")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    }
}

/// Normalized partial state -> a Hue /state body.
fn denormalize(state: &StateUpdate) -> Value {
    let mut body = Map::new();
    if let Some(on) = state.on {
        body.insert("on".into(), json!(on));
    }
    if let Some(hue) = state.hue {
        body.insert("hue".into(), json!(((hue * 65_535.0).round() as i64).clamp(0, 65_535)));
    }
    if let Some(sat) = state.saturation {
        body.insert("sat".into(), json!(((sat * 254.0).round() as i64).clamp(0, 254)));
    }
    if let Some(level) = state.level {
        // 1 is the floor (the bridge's own minimum). Off writes carry level 0
        // alongside {"on": false} — the bridge accepts bri in the same
        // command — so its stored brightness is floored too and can't
        // resurface as a stale 100% via the vendor app's toggle.
        body.insert("bri".into(), json!(((level * 254.0).round() as i64).clamp(1, 254)));
    }
    if let Some(transition) = state.transition {
        // Hue transitiontime is in 100 ms units.
        body.insert("transitiontime".into(), json!((transition * 10.0).round() as i64));
    }
    Value::Object(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hue_light(state: Value) -> Map<String, Value> {
        let raw = json!({"name": "Desk", "state": state});
        raw.as_object().unwrap().clone()
    }

    #[test]
    fn normalizes_hue_units() {
        let light = normalize(
            "1",
            &hue_light(json!({"on": true, "hue": 30000, "sat": 127, "bri": 127, "reachable": true})),
        );
        assert!((light.hue - 30_000.0 / 65_535.0).abs() < 1e-12);
        assert!((light.saturation - 0.5).abs() < 0.01);
        assert!((light.level - 0.5).abs() < 0.01);
        assert!(light.on && light.reachable);
        assert_eq!(light.name, "Desk");
    }

    #[test]
    fn normalize_defaults_missing_fields() {
        let raw = json!({}).as_object().unwrap().clone();
        let light = normalize("7", &raw);
        assert_eq!(light.name, "Light 7");
        assert!(!light.on && !light.reachable);
        assert_eq!(light.hue, 0.0);
    }

    #[test]
    fn denormalizes_with_rounding_and_clamps() {
        let body = denormalize(&StateUpdate {
            on: Some(true),
            hue: Some(0.0),
            saturation: Some(1.0),
            level: Some(1.0),
            ..Default::default()
        });
        assert_eq!(body, json!({"on": true, "hue": 0, "sat": 254, "bri": 254}));
    }

    #[test]
    fn denormalize_floors_bri_at_one() {
        let body = denormalize(&StateUpdate {
            level: Some(0.001),
            ..Default::default()
        });
        assert_eq!(body, json!({"bri": 1}));
    }

    #[test]
    fn denormalize_skips_absent_keys() {
        let body = denormalize(&StateUpdate {
            on: Some(false),
            ..Default::default()
        });
        assert_eq!(body, json!({"on": false}));
    }
}
