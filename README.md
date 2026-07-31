# HueKit

Philips Hue control: an HS color wheel, a brightness slider, and per-light
selection. The bridge URL is entered in-app on first launch (e.g. a proxy like
`https://lights.hmblair.com`) and remembered across launches.

The package (`HueKit`) is split so the logic and UI can be shared across apps:

| Target | Kind | Depends on | Platform |
|--------|------|------------|----------|
| `HueCore` | library | Foundation, Combine | any — no UI |
| `HueUI` | library | HueCore, SwiftUI | macOS + iOS |
| `HueBar` | executable | HueCore, HueUI | macOS menu-bar shell |

`HueCore` holds the model (`Light`) and `HueClient` (networking, optimistic
updates, mixed-selection checks) with no UI import. `HueUI` holds the
cross-platform SwiftUI views, including the reusable `HueControlPanel`. `HueBar`
is just the composition root and the only place AppKit appears.

## Adding an iOS app

The shared code is ready to reuse — an iOS app is a new `@main` plus a window:

```swift
import SwiftUI
import HueCore
import HueUI

@main
struct HueMobileApp: App {
    @StateObject private var client = HueClient()
    var body: some Scene {
        WindowGroup { HueControlPanel(client: client) }  // no onQuit on iOS
    }
}
```

There is no built-in bridge URL: on first launch the panel shows a **Bridge URL**
field, and the entered value is persisted to `UserDefaults` (key
`HueBridgeBaseURL`) and reused on later launches. Edit it any time via the gear
button. `UserDefaults` and `URLSession` are injectable via `HueClient.init`, so a
test can supply an isolated defaults suite and a stub session. Add the iOS app as
its own target/Xcode project depending on `HueCore` + `HueUI`.

## Run (macOS)

```sh
cd ~/dev/HueBar
swift run
```

A lightbulb icon appears in the menu bar (no Dock icon — the app runs as an
accessory). Click it for the dropdown.

## Run in the background (no terminal)

Package the app as a `.app` bundle and launch it detached:

```sh
make app       # builds .build/HueBar.app (release + Info.plist + ad-hoc sign)
make install   # copies it to /Applications
open /Applications/HueBar.app
```

`Resources/Info.plist` sets `LSUIElement`, so it runs as a background agent — no
Dock icon, no terminal. To start it automatically: System Settings → General →
Login Items → add `/Applications/HueBar.app`.

### Make targets

| Target | Does |
|--------|------|
| `make` / `make build` | debug build |
| `make release` | optimized build |
| `make run` | run in the terminal (dev) |
| `make app` (alias `bundle`) | build the `.app` bundle |
| `make install` | copy the bundle to `/Applications` |
| `make clean` | remove build artifacts |

## UI

- **Lights** — click a row to include/exclude it from control. The dot shows
  on/off; `wifi.slash` means the bridge reports it unreachable.
- **Color wheel** — angle picks hue, distance from center picks saturation.
  Sent as Hue `hue` (0–65535) / `sat` (0–254), which puts lights in `hs` mode.
  Color is power-neutral: it never turns a light on or off.
- **Brightness** — the single power+level control. 0% turns lights off
  (`on:false`); any positive value turns them on at the mapped `bri` (1–254). A
  light is off exactly when its brightness is 0 — nothing is remembered across
  off. The left sun icon sets 0% (off), the right sun icon sets 100%.

Writes are debounced (~60 ms) and fan out concurrently to every selected light.

## Notes / next steps

- The proxy exposes the datastore at the root, so endpoints are `/lights` and
  `/lights/{id}/state` (no app-key path segment). Set the bridge URL in the
  panel's Bridge settings (gear button).
- Groups/rooms (`/groups/{id}/action`) would let you control a whole room in
  one request instead of fanning out.
- A `ControlWidget` could add a quick on/off toggle to Control Center — see the
  Mission Control discussion; the color wheel has to stay in the menu bar.
