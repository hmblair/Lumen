//! HTTP API in Lumen's normalized schema.
//!
//! Lights (all values 0...1):
//!   GET /lights            -> {"lights": [{id, name, on, hue, saturation,
//!                              level, reachable}, ...]}
//!                             502 when the bridge is unreachable, so clients'
//!                             reachability logic sees a failed poll.
//!   PUT /lights/{id}       <- any subset of {on, hue, saturation, level}
//!                             200 {"ok": true} | 400 bad body | 404 unknown
//!                             light | 409 a running scene owns this light |
//!                             502 bridge
//!
//! Scenes (named curves; a solid color is the one-point, 0-duration case):
//!   GET    /scenes             -> {"scenes": {name: {duration, points}}}
//!   PUT    /scenes/{name}      <- {duration, points: [{t, hue, saturation,
//!                                 level}]} — upsert, validated here
//!   DELETE /scenes/{name}      409 while a schedule references it
//!   POST   /scenes/{name}/run  <- optional {"targets": [ids]} — run now
//!
//! Schedules (fire a scene at a time on chosen days):
//!   GET    /schedules          -> {"schedules": {name: {at, days, on?,
//!                                 scene, targets, enabled}}}
//!   PUT    /schedules/{name}   <- upsert, validated (scene must exist)
//!   DELETE /schedules/{name}
//!
//! Runs:
//!   GET  /status           -> {"running": null | {scene, schedule?, targets,
//!                              started, ends}}
//!   POST /stop             -> {"stopped": name | null}
//!
//! Author: Hamish M. Blair <hmblair@stanford.edu>

use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::Json;
use axum::routing::{delete, get, post, put};
use axum::Router;
use serde_json::{json, Value};

use crate::bridge::StateUpdate;
use crate::cache::LightCache;
use crate::runner::SceneRunner;
use crate::scenes::Scene;
use crate::scheduler::Schedule;
use crate::store::Store;

const ALLOWED_KEYS: [&str; 4] = ["on", "hue", "saturation", "level"];

type ApiResponse = (StatusCode, Json<Value>);

#[derive(Clone)]
pub struct AppState {
    pub cache: Arc<LightCache>,
    pub runner: Arc<SceneRunner>,
    pub scenes: Arc<Store<Scene>>,
    pub schedules: Arc<Store<Schedule>>,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/lights", get(get_lights))
        .route("/lights/{id}", put(put_light))
        .route("/scenes", get(get_scenes))
        .route("/scenes/{name}", put(put_scene))
        .route("/scenes/{name}", delete(delete_scene))
        .route("/scenes/{name}/run", post(run_scene))
        .route("/schedules", get(get_schedules))
        .route("/schedules/{name}", put(put_schedule))
        .route("/schedules/{name}", delete(delete_schedule))
        .route("/status", get(get_status))
        .route("/stop", post(stop))
        .with_state(state)
}

// MARK: lights

async fn get_lights(State(state): State<AppState>) -> ApiResponse {
    match state.cache.snapshot().await {
        Some(lights) => (StatusCode::OK, Json(json!({ "lights": lights }))),
        None => error(StatusCode::BAD_GATEWAY, "bridge unreachable"),
    }
}

async fn put_light(
    State(state): State<AppState>,
    Path(light_id): Path<String>,
    body: Bytes,
) -> ApiResponse {
    // Parse by hand rather than via the Json extractor so malformed bodies
    // get a consistent 400 message regardless of Content-Type.
    let Ok(Value::Object(fields)) = serde_json::from_slice::<Value>(&body) else {
        return error(StatusCode::BAD_REQUEST, "expected a JSON object");
    };

    let mut unknown: Vec<&String> = fields
        .keys()
        .filter(|k| !ALLOWED_KEYS.contains(&k.as_str()))
        .collect();
    if !unknown.is_empty() {
        unknown.sort();
        return error(StatusCode::BAD_REQUEST, &format!("unknown keys: {unknown:?}"));
    }

    let mut update = StateUpdate::default();
    for (key, value) in &fields {
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

    if let Some(lights) = state.cache.snapshot().await {
        if !lights.iter().any(|l| l.id == light_id) {
            return error(StatusCode::NOT_FOUND, &format!("no light with id {light_id}"));
        }
    }

    // Schedule-wins arbitration: a running scene owns its lights.
    if let Some(scene) = state.runner.owner_of(&light_id).await {
        return error(
            StatusCode::CONFLICT,
            &format!("scene '{scene}' is running on this light; POST /stop to take manual control"),
        );
    }

    match state.cache.apply(&light_id, &update).await {
        Ok(()) => ok(),
        Err(e) => error(StatusCode::BAD_GATEWAY, &e.to_string()),
    }
}

// MARK: scenes

async fn get_scenes(State(state): State<AppState>) -> ApiResponse {
    (StatusCode::OK, Json(json!({ "scenes": state.scenes.map().await })))
}

async fn put_scene(
    State(state): State<AppState>,
    Path(name): Path<String>,
    body: Bytes,
) -> ApiResponse {
    let mut scene: Scene = match serde_json::from_slice(&body) {
        Ok(scene) => scene,
        Err(e) => return error(StatusCode::BAD_REQUEST, &format!("invalid scene: {e}")),
    };
    if let Err(e) = scene.validate() {
        return error(StatusCode::BAD_REQUEST, &e);
    }
    state.scenes.upsert(name, scene).await;
    ok()
}

async fn delete_scene(State(state): State<AppState>, Path(name): Path<String>) -> ApiResponse {
    let referencing: Vec<String> = state
        .schedules
        .map()
        .await
        .into_iter()
        .filter(|(_, s)| s.scene == name)
        .map(|(schedule_name, _)| schedule_name)
        .collect();
    if !referencing.is_empty() {
        return error(
            StatusCode::CONFLICT,
            &format!("scene '{name}' is used by schedules: {referencing:?}"),
        );
    }
    if state.scenes.remove(&name).await {
        ok()
    } else {
        error(StatusCode::NOT_FOUND, &format!("no scene named '{name}'"))
    }
}

async fn run_scene(
    State(state): State<AppState>,
    Path(name): Path<String>,
    body: Bytes,
) -> ApiResponse {
    let Some(scene) = state.scenes.get(&name).await else {
        return error(StatusCode::NOT_FOUND, &format!("no scene named '{name}'"));
    };
    let targets = if body.is_empty() {
        vec![]
    } else {
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct RunBody {
            #[serde(default)]
            targets: Vec<String>,
        }
        match serde_json::from_slice::<RunBody>(&body) {
            Ok(run_body) => run_body.targets,
            Err(e) => return error(StatusCode::BAD_REQUEST, &format!("invalid body: {e}")),
        }
    };
    state.runner.run(&name, scene, None, targets).await;
    ok()
}

// MARK: schedules

async fn get_schedules(State(state): State<AppState>) -> ApiResponse {
    (StatusCode::OK, Json(json!({ "schedules": state.schedules.map().await })))
}

async fn put_schedule(
    State(state): State<AppState>,
    Path(name): Path<String>,
    body: Bytes,
) -> ApiResponse {
    let mut schedule: Schedule = match serde_json::from_slice(&body) {
        Ok(schedule) => schedule,
        Err(e) => return error(StatusCode::BAD_REQUEST, &format!("invalid schedule: {e}")),
    };
    if let Err(e) = schedule.validate() {
        return error(StatusCode::BAD_REQUEST, &e);
    }
    if state.scenes.get(&schedule.scene).await.is_none() {
        return error(
            StatusCode::BAD_REQUEST,
            &format!("no scene named '{}'", schedule.scene),
        );
    }
    state.schedules.upsert(name, schedule).await;
    ok()
}

async fn delete_schedule(State(state): State<AppState>, Path(name): Path<String>) -> ApiResponse {
    if state.schedules.remove(&name).await {
        ok()
    } else {
        error(StatusCode::NOT_FOUND, &format!("no schedule named '{name}'"))
    }
}

// MARK: runs

async fn get_status(State(state): State<AppState>) -> ApiResponse {
    (StatusCode::OK, Json(json!({ "running": state.runner.status().await })))
}

async fn stop(State(state): State<AppState>) -> ApiResponse {
    (StatusCode::OK, Json(json!({ "stopped": state.runner.stop().await })))
}

// MARK: helpers

fn ok() -> ApiResponse {
    (StatusCode::OK, Json(json!({ "ok": true })))
}

fn error(status: StatusCode, message: &str) -> ApiResponse {
    (status, Json(json!({ "error": message })))
}

fn bad_value(key: &str) -> ApiResponse {
    error(StatusCode::BAD_REQUEST, &format!("invalid value for key '{key}'"))
}
