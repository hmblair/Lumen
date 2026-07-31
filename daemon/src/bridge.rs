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

use crate::config::Config;

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

/// A normalized partial state update (any subset of the four keys).
#[derive(Default, Clone)]
pub struct StateUpdate {
    pub on: Option<bool>,
    pub hue: Option<f64>,
    pub saturation: Option<f64>,
    pub level: Option<f64>,
}

pub struct Bridge {
    api_key: String,
    configured_ip: Option<String>,
    client: reqwest::Client,
    /// Cached bridge IP; also serializes discovery, like the Python lock.
    ip: Mutex<Option<String>>,
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
            configured_ip: config.bridge_ip,
            client,
            ip: Mutex::new(None),
        }
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
        self.request(reqwest::Method::PUT, &path, Some(denormalize(state)))
            .await
            .map_err(|e| BridgeError(format!("write to light {light_id} failed: {e}")))?;
        Ok(())
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

    /// The cached bridge IP, resolving it on first use: the configured value
    /// if set, otherwise mDNS discovery.
    async fn current_ip(&self) -> Result<String, BridgeError> {
        let mut guard = self.ip.lock().await;
        if let Some(ip) = guard.as_ref() {
            return Ok(ip.clone());
        }
        if let Some(ip) = &self.configured_ip {
            *guard = Some(ip.clone());
            return Ok(ip.clone());
        }
        match discover().await {
            Some(ip) => {
                info!("Discovered Hue bridge at {ip} via mDNS");
                *guard = Some(ip.clone());
                Ok(ip)
            }
            None => Err(BridgeError(
                "no BRIDGE_IP configured and mDNS discovery failed".into(),
            )),
        }
    }

    /// Re-run mDNS and update the cached IP if a different one is found.
    /// Returns true if the cached IP changed. Runs even with a configured
    /// BRIDGE_IP, matching the Python daemon: a live discovery beats a stale
    /// config value when the configured address stops answering.
    async fn rediscover(&self) -> bool {
        let mut guard = self.ip.lock().await;
        let prev = guard.clone();
        match discover().await {
            Some(new_ip) if prev.as_deref() != Some(new_ip.as_str()) => {
                info!(
                    "Bridge IP changed: {} -> {new_ip}",
                    prev.as_deref().unwrap_or("none")
                );
                *guard = Some(new_ip);
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
        // 1 is the floor: clients express "off" as {"on": false}, never level 0.
        body.insert("bri".into(), json!(((level * 254.0).round() as i64).clamp(1, 254)));
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
