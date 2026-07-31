# lumen-daemon

The Linux half of Lumen: a small always-on Rust daemon that owns all
provider-specific (Philips Hue) translation and serves a normalized lights
API. The Swift app is pure UI + networking against this schema; supporting
another light vendor means rewriting `src/bridge.rs` only.

```
Lumen.app ── https://lumen.hmblair.com (Caddy, TLS, Tailscale-only)
                 └── 127.0.0.1:8600  lumen-daemon
                          └── https://<bridge-ip>/api/<key>  Philips Hue bridge
```

The daemon polls the bridge once a second and serves cached state, so any
number of clients can poll without multiplying bridge traffic. Writes go
through synchronously and patch the cache optimistically.

## API (all values normalized to 0...1)

| Endpoint | Body / response |
|----------|-----------------|
| `GET /lights` | `{"lights": [{id, name, on, hue, saturation, level, reachable}]}`; **502** while the bridge is unreachable |
| `PUT /lights/<id>` | any subset of `{on, hue, saturation, level, name}`; state writes **409** while a running scene owns the light (renames pass — they aren't state) |
| `GET /scenes` | `{"scenes": {name: {duration, lights: {id: [{t, hue, saturation, level}]}}}}` |
| `PUT /scenes/<name>` | same shape — upsert |
| `DELETE /scenes/<name>` | **409** while a schedule references it |
| `POST /scenes/<name>/run` | run now (the scene says which lights) |
| `GET /schedules` | `{"schedules": {name: {at, days, on?, scene, enabled}}}` |
| `PUT /schedules/<name>` | upsert; validated (time, days, scene must exist) |
| `DELETE /schedules/<name>` | |
| `GET /status` | `{"running": null \| {scene, schedule?, targets, started, ends}}` |
| `POST /stop` | `{"stopped": name \| null}` — release manual control |
| `GET /config` | `{"bridgeIP": override \| null, "activeIP", "bridgeReachable"}` |
| `PUT /config` | `{"bridgeIP": "10.0.0.5" \| null}` — null = auto (mDNS); probed before committing, persisted to config.env |

`level` is device brightness independent of `on`; clients express "off" as
`{"on": false}` (level 0 is never sent to /lights).

**Scenes** carry everything about *what* happens: each light the scene
touches maps to its own curve — points on a 0...1 timeline, interpolated per
channel and stepped over `duration` seconds. A solid color is a one-point,
zero-duration curve; `level: 0` means off; lights not in the map are left
alone (several lights sharing a curve simply repeat it). `sunrise`/`sunset`
are seeded on first contact with the bridge, instantiated per light with
huectl's field-tested keyframes — stored in `~/.config/lumen/scenes.json`
and editable like any user scene.

**Schedules** are time-only: fire a scene at `at` (`"HH:MM"`, box-local) on
`days` (`["mon"..."sun"]`) or once on a date (`on: "YYYY-MM-DD"`,
self-deleting). Stored in `~/.config/lumen/schedules.json`.

**Arbitration** is schedule-wins, uniformly: while a timed scene runs it owns
its targets — manual writes to them 409, new scene runs 409, and scheduled
fires are skipped with a warning, until the scene finishes or `POST /stop`.
An instant (0-duration) scene releases as soon as its write lands.

## Configuration

`~/.config/lumen/config.env`:

```bash
API_KEY="your-hue-api-key"
# BRIDGE_IP="10.0.0.5"   # optional; auto-discovered via mDNS if unset,
                         # and rediscovered when the cached IP stops answering
```

`BRIDGE_IP` is also settable at runtime via `PUT /config` (the app's settings
screen) — changes are probed first and written back to this file.

`LUMEN_DAEMON_PORT` overrides the default port 8600. The port is internal to
the box: only the systemd unit and Caddy's `reverse_proxy` line ever see it.

## Build & deploy

Built on the box (single self-contained binary, no runtime dependencies):

```sh
cargo build --release
cargo test                 # unit tests for the Hue unit conversions
```

Run it on an always-on machine on the same network as the bridge, from a
clone of this repo. A systemd **user** unit is provided in `systemd/`
(enable lingering so it survives logout), and clients reach the daemon
through whatever reverse proxy provides your TLS. Deploying an update is
`git pull`, rebuild, restart.

## History

Started as a Python daemon repurposing pieces of `huectl` (the previous
scheduler daemon on this box), then ported to Rust for a single static binary
— behavior-identical, parity-tested against the Python implementation before
it was retired. huectl's scheduler and effects (sunrise etc.) arrive here in
phase 2.
