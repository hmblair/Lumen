//! lumen-daemon entry point: start the poll task and the scheduler, serve
//! the HTTP API.
//!
//! Listens on 127.0.0.1 only; Caddy provides TLS and the public name.
//!
//! Author: Hamish M. Blair <hmblair@stanford.edu>

mod api;
mod bridge;
mod cache;
mod config;
mod runner;
mod scenes;
mod scheduler;
mod store;

use std::sync::Arc;

use tracing::info;

const DEFAULT_PORT: u16 = 8600;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt().init();
    let config = config::load(); // exits with a clear message on missing config
    let data_dir = config::config_path().parent().expect("config has a dir").to_path_buf();

    let bridge = Arc::new(bridge::Bridge::new(config));
    let cache = Arc::new(cache::LightCache::new(bridge));
    cache.spawn_poll_loop();

    let scenes = Arc::new(store::Store::load(data_dir.join("scenes.json"), Default::default()));
    let schedules = Arc::new(store::Store::load(data_dir.join("schedules.json"), Default::default()));
    // Presets need real light ids, so they seed once the bridge is first seen.
    scenes::spawn_preset_seeder(Arc::clone(&scenes), Arc::clone(&cache));
    let runner = Arc::new(runner::SceneRunner::new(Arc::clone(&cache)));
    scheduler::spawn_scheduler(Arc::clone(&schedules), Arc::clone(&scenes), Arc::clone(&runner));

    let state = api::AppState { cache, runner, scenes, schedules };

    let port = std::env::var("LUMEN_DAEMON_PORT")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(DEFAULT_PORT);

    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port))
        .await
        .unwrap_or_else(|e| panic!("failed to bind 127.0.0.1:{port}: {e}"));
    info!("lumen-daemon listening on http://127.0.0.1:{port}");
    axum::serve(listener, api::router(state)).await.unwrap();
}
