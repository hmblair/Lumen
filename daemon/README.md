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
| `PUT /lights/<id>` | any subset of `{on, hue, saturation, level}`; `{"ok": true}` |
| `GET /status` | `{"running": null}` — phase-2 scheduler placeholder: will report the effect that owns lights so clients can grey out manual control |

`level` is device brightness independent of `on`; clients express "off" as
`{"on": false}` (level 0 is never sent).

## Configuration

`~/.config/lumen/config.env`:

```bash
API_KEY="your-hue-api-key"
# BRIDGE_IP="10.0.0.5"   # optional; auto-discovered via mDNS if unset,
                         # and rediscovered when the cached IP stops answering
```

`LUMEN_DAEMON_PORT` overrides the default port 8600. The port is internal to
the box: only the systemd unit and Caddy's `reverse_proxy` line ever see it.

## Build & deploy

Built on the box (single self-contained binary, no runtime dependencies):

```sh
cargo build --release
cargo test                 # unit tests for the Hue unit conversions
```

The box runs `~/dev/lumen-daemon` under the systemd **user** unit in
`systemd/` (lingering is enabled, so it runs without a login session).
Interim deploy is rsync of this directory + `cargo build --release` there;
the intended flow is pull-from-GitHub + build on the box. Public exposure is
`cloudflare-expose add lumen 8600` — DNS, Caddy block, and TLS are managed by
that tool.

## History

Started as a Python daemon repurposing pieces of `huectl` (the previous
scheduler daemon on this box), then ported to Rust for a single static binary
— behavior-identical, parity-tested against the Python implementation before
it was retired. huectl's scheduler and effects (sunrise etc.) arrive here in
phase 2.
