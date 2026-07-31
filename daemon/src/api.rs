//! HTTP API in Lumen's normalized schema — behavior-identical to the Python
//! daemon's api.py:
//!
//!   GET /lights            -> {"lights": [{id, name, on, hue, saturation,
//!                              level, reachable}, ...]}
//!                             502 when the bridge is unreachable, so clients'
//!                             reachability logic sees a failed poll.
//!   PUT /lights/{id}       <- any subset of {on, hue, saturation, level}
//!                             200 {"ok": true} | 400 bad body | 404 unknown
//!                             light | 502 bridge
//!   GET /status            -> {"running": null}   (phase-2 scheduler
//!                             placeholder: will report the effect that owns
//!                             lights so clients can grey out manual control)
//!
//! Author: Hamish M. Blair <hmblair@stanford.edu>

use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::Json;
use axum::routing::{get, put};
use axum::Router;
use serde_json::{json, Value};

use crate::bridge::StateUpdate;
use crate::cache::LightCache;

const ALLOWED_KEYS: [&str; 4] = ["on", "hue", "saturation", "level"];

type ApiResponse = (StatusCode, Json<Value>);

pub fn router(cache: Arc<LightCache>) -> Router {
    Router::new()
        .route("/lights", get(get_lights))
        .route("/lights/{id}", put(put_light))
        .route("/status", get(get_status))
        .with_state(cache)
}

async fn get_lights(State(cache): State<Arc<LightCache>>) -> ApiResponse {
    match cache.snapshot().await {
        Some(lights) => (StatusCode::OK, Json(json!({ "lights": lights }))),
        None => bridge_unreachable(),
    }
}

async fn get_status() -> ApiResponse {
    (StatusCode::OK, Json(json!({ "running": null })))
}

async fn put_light(
    State(cache): State<Arc<LightCache>>,
    Path(light_id): Path<String>,
    body: Bytes,
) -> ApiResponse {
    // Parse by hand rather than via the Json extractor so malformed bodies get
    // the same 400 message as the Python daemon, regardless of Content-Type.
    let Ok(Value::Object(state)) = serde_json::from_slice::<Value>(&body) else {
        return error(StatusCode::BAD_REQUEST, "expected a JSON object");
    };

    let mut unknown: Vec<&String> = state
        .keys()
        .filter(|k| !ALLOWED_KEYS.contains(&k.as_str()))
        .collect();
    if !unknown.is_empty() {
        unknown.sort();
        return error(StatusCode::BAD_REQUEST, &format!("unknown keys: {unknown:?}"));
    }

    let mut update = StateUpdate::default();
    for (key, value) in &state {
        match key.as_str() {
            "on" => match value.as_bool() {
                Some(on) => update.on = Some(on),
                None => return bad_value(key),
            },
            _ => match value.as_f64() {
                Some(number) => match key.as_str() {
                    "hue" => update.hue = Some(number),
                    "saturation" => update.saturation = Some(number),
                    _ => update.level = Some(number),
                },
                None => return bad_value(key),
            },
        }
    }

    if let Some(lights) = cache.snapshot().await {
        if !lights.iter().any(|l| l.id == light_id) {
            return error(
                StatusCode::NOT_FOUND,
                &format!("no light with id {light_id}"),
            );
        }
    }

    match cache.apply(&light_id, &update).await {
        Ok(()) => (StatusCode::OK, Json(json!({ "ok": true }))),
        Err(e) => error(StatusCode::BAD_GATEWAY, &e.to_string()),
    }
}

fn error(status: StatusCode, message: &str) -> ApiResponse {
    (status, Json(json!({ "error": message })))
}

fn bad_value(key: &str) -> ApiResponse {
    error(
        StatusCode::BAD_REQUEST,
        &format!("invalid value for key '{key}'"),
    )
}

fn bridge_unreachable() -> ApiResponse {
    error(StatusCode::BAD_GATEWAY, "bridge unreachable")
}
