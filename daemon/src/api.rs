//! HTTP API in Lumen's normalized schema.
//!
//! Lights (all values 0...1):
//!   GET /lights            -> {"lights": [{id, name, on, hue, saturation,
//!                              level, reachable}, ...]}
//!                             502 when the bridge is unreachable, so clients'
//!                             reachability logic sees a failed poll.
//!   PUT /lights/{id}       <- any subset of {on, hue, saturation, level,
//!                             name} — name renames the light on the bridge
//!                             (not arbitrated: it isn't light state)
//!                             200 {"ok": true} | 400 bad body | 404 unknown
//!                             light | 409 a running scene owns this light |
//!                             502 bridge
//!
//! Scenes (named per-light programs; a solid color is a one-point,
//! 0-duration curve):
//!   GET    /scenes             -> {"scenes": {name: {duration, lights:
//!                                 {id: [{t, hue, saturation, level}]}}}}
//!   PUT    /scenes/{name}      <- same shape — upsert, validated here
//!   DELETE /scenes/{name}      409 while a schedule references it
//!   POST   /scenes/{name}/run  run now (the scene says which lights)
//!
//! Schedules (time-only: fire a scene at a time on chosen days):
//!   GET    /schedules          -> {"schedules": {name: {at, days, on?,
//!                                 scene, enabled}}}
//!   PUT    /schedules/{name}   <- upsert, validated (scene must exist)
//!   DELETE /schedules/{name}
//!
//! Runs:
//!   GET  /status           -> {"running": null | {scene, schedule?, targets,
//!                              started, ends}}
//!   POST /stop             -> {"stopped": name | null}
//!
//! Groups (bridge-native, so the vendor ecosystem sees the same membership;
//! created as overlapping-capable LightGroups):
//!   GET    /groups          -> {"groups": {id: {name, lights}}}
//!   POST   /groups          <- {name, lights} -> {"ok": true, "id": id}
//!   PUT    /groups/{id}     <- any subset of {on, hue, saturation, level,
//!                             name, lights} — state applies atomically to
//!                             every member (409 if a scene owns any);
//!                             name/lights update the group itself
//!   DELETE /groups/{id}     (member lights are unaffected)
//!
//! Config:
//!   GET /config            -> {"bridgeIP": override | null, "activeIP":
//!                              in-use address | null, "bridgeReachable"}
//!   PUT /config            <- {"bridgeIP": "10.0.0.5" | null} — null/empty
//!                              = auto (mDNS); probed before committing, then
//!                              persisted to config.env
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

use crate::bridge::{Bridge, StateUpdate};
use crate::cache::LightCache;
use crate::runner::SceneRunner;
use crate::scenes::Scene;
use crate::scheduler::Schedule;
use crate::store::Store;

const ALLOWED_KEYS: [&str; 5] = ["on", "hue", "saturation", "level", "name"];

type ApiResponse = (StatusCode, Json<Value>);

#[derive(Clone)]
pub struct AppState {
    pub bridge: Arc<Bridge>,
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
        .route("/groups", get(get_groups))
        .route("/groups", post(post_group))
        .route("/groups/{id}", put(put_group))
        .route("/groups/{id}", delete(delete_group))
        .route("/status", get(get_status))
        .route("/stop", post(stop))
        .route("/config", get(get_config))
        .route("/config", put(put_config))
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
    let mut new_name: Option<String> = None;
    for (key, value) in &fields {
        match key.as_str() {
            "on" => match value.as_bool() {
                Some(on) => update.on = Some(on),
                None => return bad_value(key),
            },
            "name" => match value.as_str().map(str::trim) {
                // 32 chars is the bridge's own limit.
                Some(name) if !name.is_empty() && name.chars().count() <= 32 => {
                    new_name = Some(name.to_string());
                }
                _ => return error(
                    StatusCode::BAD_REQUEST,
                    "name must be a non-empty string of at most 32 characters",
                ),
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

    // Schedule-wins arbitration: a running scene owns its lights' *state*.
    // A rename isn't state, so it passes — but a mixed request is refused
    // whole rather than half-applied.
    let has_state = update.on.is_some() || update.hue.is_some()
        || update.saturation.is_some() || update.level.is_some();
    if has_state {
        if let Some(scene) = state.runner.owner_of(&light_id).await {
            return error(
                StatusCode::CONFLICT,
                &format!("scene '{scene}' is running on this light; POST /stop to take manual control"),
            );
        }
    }

    if let Some(name) = new_name {
        if let Err(e) = state.cache.rename(&light_id, &name).await {
            return error(StatusCode::BAD_GATEWAY, &e.to_string());
        }
    }
    if has_state {
        if let Err(e) = state.cache.apply(&light_id, &update).await {
            return error(StatusCode::BAD_GATEWAY, &e.to_string());
        }
    }
    ok()
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

async fn run_scene(State(state): State<AppState>, Path(name): Path<String>) -> ApiResponse {
    let Some(scene) = state.scenes.get(&name).await else {
        return error(StatusCode::NOT_FOUND, &format!("no scene named '{name}'"));
    };
    match state.runner.run(&name, scene, None).await {
        Ok(()) => ok(),
        Err(running) => error(
            StatusCode::CONFLICT,
            &format!("scene '{running}' is running; POST /stop to take over"),
        ),
    }
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

// MARK: groups

async fn get_groups(State(state): State<AppState>) -> ApiResponse {
    match state.cache.groups().await {
        Some(groups) => {
            let map: serde_json::Map<String, Value> = groups
                .into_iter()
                .map(|g| (g.id, json!({ "name": g.name, "lights": g.lights })))
                .collect();
            (StatusCode::OK, Json(json!({ "groups": map })))
        }
        None => error(StatusCode::BAD_GATEWAY, "bridge unreachable"),
    }
}

/// Validate a group name (bridge limit: 32 chars) from a JSON value.
fn parse_group_name(value: &Value) -> Result<String, ApiResponse> {
    match value.as_str().map(str::trim) {
        Some(name) if !name.is_empty() && name.chars().count() <= 32 => Ok(name.to_string()),
        _ => Err(error(
            StatusCode::BAD_REQUEST,
            "name must be a non-empty string of at most 32 characters",
        )),
    }
}

/// Validate a member list: string ids that all exist (when light state is
/// known).
async fn parse_group_lights(state: &AppState, value: &Value) -> Result<Vec<String>, ApiResponse> {
    let Some(ids) = value.as_array().map(|a| {
        a.iter()
            .filter_map(|v| v.as_str().map(str::to_string))
            .collect::<Vec<_>>()
    }) else {
        return Err(error(StatusCode::BAD_REQUEST, "lights must be an array of light ids"));
    };
    if ids.is_empty() {
        return Err(error(StatusCode::BAD_REQUEST, "a group needs at least one light"));
    }
    if let Some(lights) = state.cache.snapshot().await {
        for id in &ids {
            if !lights.iter().any(|l| &l.id == id) {
                return Err(error(StatusCode::NOT_FOUND, &format!("no light with id {id}")));
            }
        }
    }
    Ok(ids)
}

async fn post_group(State(state): State<AppState>, body: Bytes) -> ApiResponse {
    let Ok(Value::Object(fields)) = serde_json::from_slice::<Value>(&body) else {
        return error(StatusCode::BAD_REQUEST, "expected a JSON object");
    };
    if fields.keys().any(|k| k != "name" && k != "lights") {
        return error(StatusCode::BAD_REQUEST, "expected only 'name' and 'lights'");
    }
    let (Some(name_value), Some(lights_value)) = (fields.get("name"), fields.get("lights")) else {
        return error(StatusCode::BAD_REQUEST, "both 'name' and 'lights' are required");
    };
    let name = match parse_group_name(name_value) {
        Ok(name) => name,
        Err(response) => return response,
    };
    let lights = match parse_group_lights(&state, lights_value).await {
        Ok(lights) => lights,
        Err(response) => return response,
    };
    match state.cache.create_group(&name, &lights).await {
        Ok(id) => (StatusCode::OK, Json(json!({ "ok": true, "id": id }))),
        Err(e) => error(StatusCode::BAD_GATEWAY, &e.to_string()),
    }
}

async fn put_group(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    body: Bytes,
) -> ApiResponse {
    let Ok(Value::Object(fields)) = serde_json::from_slice::<Value>(&body) else {
        return error(StatusCode::BAD_REQUEST, "expected a JSON object");
    };
    const GROUP_KEYS: [&str; 6] = ["on", "hue", "saturation", "level", "name", "lights"];
    let mut unknown: Vec<&String> =
        fields.keys().filter(|k| !GROUP_KEYS.contains(&k.as_str())).collect();
    if !unknown.is_empty() {
        unknown.sort();
        return error(StatusCode::BAD_REQUEST, &format!("unknown keys: {unknown:?}"));
    }

    let Some(groups) = state.cache.groups().await else {
        return error(StatusCode::BAD_GATEWAY, "bridge unreachable");
    };
    let Some(group) = groups.iter().find(|g| g.id == group_id) else {
        return error(StatusCode::NOT_FOUND, &format!("no group with id {group_id}"));
    };

    let mut update = StateUpdate::default();
    let mut new_name: Option<String> = None;
    let mut new_lights: Option<Vec<String>> = None;
    for (key, value) in &fields {
        match key.as_str() {
            "on" => match value.as_bool() {
                Some(on) => update.on = Some(on),
                None => return bad_value(key),
            },
            "name" => match parse_group_name(value) {
                Ok(name) => new_name = Some(name),
                Err(response) => return response,
            },
            "lights" => match parse_group_lights(&state, value).await {
                Ok(lights) => new_lights = Some(lights),
                Err(response) => return response,
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

    // State applies atomically to every member — arbitrated like light
    // writes: refused whole if a running scene owns any member.
    let has_state = update.on.is_some() || update.hue.is_some()
        || update.saturation.is_some() || update.level.is_some();
    if has_state {
        for member in &group.lights {
            if let Some(scene) = state.runner.owner_of(member).await {
                return error(
                    StatusCode::CONFLICT,
                    &format!("scene '{scene}' is running on this group's lights; POST /stop to take manual control"),
                );
            }
        }
    }

    if new_name.is_some() || new_lights.is_some() {
        if let Err(e) = state
            .cache
            .update_group(&group_id, new_name.as_deref(), new_lights.as_deref())
            .await
        {
            return error(StatusCode::BAD_GATEWAY, &e.to_string());
        }
    }
    if has_state {
        if let Err(e) = state.cache.apply_group(&group_id, &update).await {
            return error(StatusCode::BAD_GATEWAY, &e.to_string());
        }
    }
    ok()
}

async fn delete_group(State(state): State<AppState>, Path(group_id): Path<String>) -> ApiResponse {
    match state.cache.groups().await {
        Some(groups) if !groups.iter().any(|g| g.id == group_id) => {
            return error(StatusCode::NOT_FOUND, &format!("no group with id {group_id}"));
        }
        None => return error(StatusCode::BAD_GATEWAY, "bridge unreachable"),
        _ => {}
    }
    match state.cache.delete_group(&group_id).await {
        Ok(()) => ok(),
        Err(e) => error(StatusCode::BAD_GATEWAY, &e.to_string()),
    }
}

// MARK: config

async fn get_config(State(state): State<AppState>) -> ApiResponse {
    let (configured, active) = state.bridge.ip_state().await;
    (
        StatusCode::OK,
        Json(json!({
            "bridgeIP": configured,
            "activeIP": active,
            "bridgeReachable": state.cache.snapshot().await.is_some(),
        })),
    )
}

async fn put_config(State(state): State<AppState>, body: Bytes) -> ApiResponse {
    let Ok(Value::Object(fields)) = serde_json::from_slice::<Value>(&body) else {
        return error(StatusCode::BAD_REQUEST, "expected a JSON object");
    };
    if fields.keys().any(|k| k != "bridgeIP") {
        return error(StatusCode::BAD_REQUEST, "the only settable key is 'bridgeIP'");
    }
    let ip = match fields.get("bridgeIP") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if s.trim().is_empty() => None,
        Some(Value::String(s)) => Some(s.trim().to_string()),
        Some(_) => return error(StatusCode::BAD_REQUEST, "bridgeIP must be a string or null"),
    };
    match state.bridge.set_configured_ip(ip).await {
        Ok(()) => ok(),
        Err(e) => error(StatusCode::BAD_GATEWAY, &e.to_string()),
    }
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
