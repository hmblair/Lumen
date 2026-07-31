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

    Config { api_key, bridge_ip }
}
