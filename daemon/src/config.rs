//! Runtime configuration from ~/.config/lumen/config.env.
//!
//! Same file and format as the Python daemon: KEY=VALUE lines, `#` comments,
//! optional surrounding quotes. API_KEY is required; BRIDGE_IP is optional
//! (mDNS discovery when unset), with the historical placeholder values
//! treated as unset.
//!
//! Author: Hamish M. Blair <hmblair@stanford.edu>

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::exit;

const PLACEHOLDER_IPS: [&str; 2] = ["", "your-bridge-ip"];

#[derive(Clone)]
pub struct Config {
    pub api_key: String,
    pub bridge_ip: Option<String>,
    /// Where the box is on Earth, for sunrise/sunset schedules. Optional;
    /// solar schedules stay dormant without it.
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
}

pub fn config_path() -> PathBuf {
    let home = std::env::var("HOME").expect("HOME is not set");
    PathBuf::from(home).join(".config/lumen/config.env")
}

/// Load config.env; exits with a clear message if it's missing or incomplete,
/// so a misconfiguration fails at startup rather than on the first request.
pub fn load() -> Config {
    let path = config_path();
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) => {
            eprintln!("Error: failed to load {}: {e}", path.display());
            eprintln!("Create it with API_KEY (BRIDGE_IP optional; auto-discovered via mDNS).");
            exit(1);
        }
    };

    let mut values: HashMap<String, String> = HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((key, value)) = line.split_once('=') {
            values.insert(
                key.trim().to_string(),
                value.trim().trim_matches('"').to_string(),
            );
        }
    }

    let Some(api_key) = values.get("API_KEY").cloned() else {
        eprintln!("Error: failed to load {}: API_KEY", path.display());
        eprintln!("Create it with API_KEY (BRIDGE_IP optional; auto-discovered via mDNS).");
        exit(1);
    };

    let bridge_ip = values
        .get("BRIDGE_IP")
        .filter(|ip| !PLACEHOLDER_IPS.contains(&ip.as_str()))
        .cloned();

    let coordinate = |key: &str| values.get(key).and_then(|v| v.parse::<f64>().ok());
    let latitude = coordinate("LATITUDE");
    let longitude = coordinate("LONGITUDE");

    Config { api_key, bridge_ip, latitude, longitude }
}

/// Persist a changed BRIDGE_IP (None = auto-discovery) back to config.env,
/// leaving every other line — API_KEY, comments — untouched.
pub fn persist_bridge_ip(ip: Option<&str>) {
    let path = config_path();
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    let mut lines: Vec<String> = text
        .lines()
        .filter(|line| !line.trim_start().starts_with("BRIDGE_IP"))
        .map(str::to_string)
        .collect();
    if let Some(ip) = ip {
        lines.push(format!("BRIDGE_IP=\"{ip}\""));
    }
    if let Err(e) = std::fs::write(&path, lines.join("\n") + "\n") {
        tracing::warn!("Failed to persist BRIDGE_IP to {}: {e}", path.display());
    }
}
