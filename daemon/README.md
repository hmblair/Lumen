# lumen-daemon

The Linux half of Lumen: a small always-on Rust daemon that owns all
provider-specific (Philips Hue) translation and serves a normalized lights
API. Clients are pure UI + networking against this schema; supporting another
light vendor means rewriting `src/bridge.rs` only.

```
Lumen.app ── https://lumen.example.com (reverse proxy, TLS)
                 └── 127.0.0.1:8600  lumen-daemon
                          └── https://<bridge-ip>/api/<key>  Philips Hue bridge
```

The daemon polls the bridge once a second and serves cached state, so any
number of clients can poll without multiplying bridge traffic. Writes go
through synchronously and patch the cache optimistically.

## Quickstart

Run it on an always-on machine on the same network as the bridge.

```sh
mkdir -p ~/.config/lumen
cat > ~/.config/lumen/config.env <<'EOF'
API_KEY="your-hue-api-key"
# BRIDGE_IP="10.0.0.5"   # optional; auto-discovered via mDNS if unset, and
                         # rediscovered when the cached IP stops answering
# LATITUDE="37.43"       # optional; enables sunrise/sunset schedules
# LONGITUDE="-122.17"    # (two decimals ≈ 1 km — plenty for sun times)
EOF

cargo build --release
cargo test                 # Hue unit conversions, scene curves, schedule matching
./target/release/lumen-daemon
```

The binary is self-contained — no runtime dependencies. A systemd **user** unit
is provided in `systemd/` (enable lingering so it survives logout), and clients
reach the daemon through whatever reverse proxy provides your TLS. Deploying an
update is `git pull`, rebuild, restart.

`LUMEN_DAEMON_PORT` overrides the default port 8600; the port is internal to
the box, seen only by the systemd unit and the proxy. `BRIDGE_IP` is also
settable at runtime via `PUT /config` (the app's settings screen) — changes are
probed before committing and written back to config.env.

## API (all values normalized to 0...1)

| Endpoint | Body / response |
|----------|-----------------|
| `GET /` | `{"service": "lumen-daemon", "ok": true}` — health probe |
| `GET /lights` | `{"lights": [{id, name, on, hue, saturation, level, reachable}]}`; **502** while the bridge is unreachable |
| `PUT /lights/<id>` | any subset of `{on, hue, saturation, level, name}`; state writes **409** while a running scene owns the light (renames pass — they aren't state) |
| `GET /scenes` | `{"scenes": {name: {duration, lights: {id: [{t, hue, saturation, level}]}}}}` |
| `PUT /scenes/<name>` | same shape — upsert |
| `POST /scenes/<name>/rename` | `{"to": "new name"}` — repoints the schedules that reference it |
| `POST /scenes/<name>/run` | run now (the scene says which lights) |
| `DELETE /scenes/<name>` | **409** while a schedule references it |
| `GET /schedules` | `{"schedules": {name: {at, days, on?, scene, enabled}}}` |
| `PUT /schedules/<name>` | upsert; validated (time, days, scene must exist; `sunrise`/`sunset` need a configured location) |
| `DELETE /schedules/<name>` | |
| `GET /groups` | `{"groups": {id: {name, lights}}}` — daemon-authoritative rooms (may be empty; served even with the bridge down) |
| `POST /groups` | `{name, lights}` (lights may be `[]`) → `{"ok": true, "id": id}` |
| `PUT /groups/<id>` | any subset of `{on, hue, saturation, level, name, lights}`; state applies to all members — atomically via the bridge mirror when one exists (**409** if a scene owns any) |
| `DELETE /groups/<id>` | member lights are unaffected |
| `GET /status` | `{"running": null \| {scene, schedule?, targets, started, ends}}` |
| `POST /stop` | `{"stopped": name \| null}` — release manual control |
| `GET /config` | `{"bridgeIP": override \| null, "activeIP", "bridgeReachable", "sunrise", "sunset"}` — the solar fields are today's `"HH:MM"` (box-local), `null` without a configured location |
| `PUT /config` | `{"bridgeIP": "10.0.0.5" \| null}` — null = auto (mDNS); probed before committing, persisted to config.env |

`level` is device brightness independent of `on`; clients express "off" as
`{"on": false}` (level 0 is never sent to /lights).

## Model

**Scenes** carry everything about *what* happens: each light the scene touches
maps to its own curve — points on a 0...1 timeline, interpolated per channel
and stepped over `duration` seconds. A solid color is a one-point,
zero-duration curve; `level: 0` means off; lights not in the map are left alone
(several lights sharing a curve simply repeat it). `sunrise`/`sunset` are
seeded on first contact with the bridge, instantiated per light with huectl's
field-tested keyframes — stored in `~/.config/lumen/scenes.json` and editable
like any user scene.

**Schedules** are the *when*: fire a scene at `at` on `days`
(`["mon"..."sun"]`) or once on a date (`on: "YYYY-MM-DD"`, self-deleting). `at`
is `"HH:MM"` (box-local) or the literals `"sunrise"`/`"sunset"`, resolved daily
from the configured `LATITUDE`/`LONGITUDE` — pure local math (NOAA, via the
`sunrise` crate), no network. Solar schedules lie dormant if the location is
removed. Stored in `~/.config/lumen/schedules.json`. A schedule is due for the whole window its scene occupies, from `at` until the scene's duration has passed. A schedule added or edited inside that window starts its scene at the matching point of the timeline, and a daemon restart inside the window resumes the scene. Editing a schedule or its scene, or disabling or deleting the schedule, stops the run; while the window is still open the next tick starts the new version at the matching point.

**Rooms** live in `~/.config/lumen/rooms.json` with daemon-generated ids — the
daemon, not the bridge, is their source of truth. Each room with lights is
mirrored to a bridge group purely so the vendor's own app stays coherent (the
bridge refuses empty groups, so an emptied room just loses its mirror until a
light returns); mirroring is best-effort and never fails a room operation. On
first run, existing bridge groups are imported once.

**Arbitration** is schedule-wins, uniformly: while a timed scene runs it owns
its targets — manual writes to them 409, new scene runs 409, and scheduled
fires wait, retrying each tick while their window stays open, until the scene
finishes or `POST /stop`. An instant (0-duration) scene releases as soon as
its write lands.

## History

Started as a Python daemon repurposing pieces of `huectl` (the previous
scheduler daemon), then ported to Rust for a single static binary —
behavior-identical, parity-tested against the Python implementation before it
was retired. huectl's scheduler and effects (sunrise etc.) now live here.
