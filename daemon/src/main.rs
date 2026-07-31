//! lumen-daemon entry point: start the poll task, serve the HTTP API.
//!
//! Listens on 127.0.0.1 only; Caddy provides TLS and the public name.
//! Behavior-identical Rust port of the Python daemon (daemon/); same config
//! file, same env vars, same endpoints, so the two are drop-in swappable
//! behind the same systemd unit.
//!
//! Author: Hamish M. Blair <hmblair@stanford.edu>

mod api;
mod bridge;
mod cache;
mod config;

use std::sync::Arc;

use tracing::info;

const DEFAULT_PORT: u16 = 8600;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt().init();
    let config = config::load(); // exits with a clear message on missing config

    let bridge = Arc::new(bridge::Bridge::new(config));
    let cache = Arc::new(cache::LightCache::new(bridge));
    cache.spawn_poll_loop();

    let port = std::env::var("LUMEN_DAEMON_PORT")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(DEFAULT_PORT);

    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port))
        .await
        .unwrap_or_else(|e| panic!("failed to bind 127.0.0.1:{port}: {e}"));
    info!("lumen-daemon listening on http://127.0.0.1:{port}");
    axum::serve(listener, api::router(cache)).await.unwrap();
}
