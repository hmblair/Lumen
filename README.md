# Lumen

A menu-bar smart-light controller: an HS color wheel, a brightness slider, and
per-light selection. The server URL is entered in-app on first launch (e.g.
`https://lumen.hmblair.com`, the Lumen daemon) and remembered across launches.

The package (`Lumen`) is split so the logic and UI can be shared across apps,
and so the provider-specific code is isolated:

| Target | Kind | Depends on | Platform |
|--------|------|------------|----------|
| `LumenCore` | library | Foundation, Combine | any — no UI |
| `LumenUI` | library | LumenCore, SwiftUI | macOS + iOS |
| `Lumen` | executable | LumenCore, LumenUI | macOS menu-bar shell |

`LumenCore` holds the model (`Light`) and `LightController` (networking,
optimistic updates, mixed-selection checks) with no UI import. `LumenUI` holds
the cross-platform SwiftUI views, including the reusable `ControlPanel`. `Lumen`
is just the composition root and the only place AppKit appears.

## Provider-agnostic by design

The apps contain nothing provider-specific at all. They speak the normalized
schema of the Lumen daemon (see [daemon/](daemon/README.md)) — a small
always-on service that polls the light source, serves cached state, and owns
every vendor detail (currently Philips Hue). All values are `0…1` on the wire
and in the model; supporting another vendor means rewriting the daemon's
`bridge.rs`, and no app updates at all.

```
Lumen.app / iOS ── https://lumen.hmblair.com (Caddy)
                        └── lumen-daemon ── Philips Hue bridge
```

## Adding an iOS app

The shared code is ready to reuse — an iOS app is a new `@main` plus a window:

```swift
import SwiftUI
import LumenCore
import LumenUI

@main
struct LumenMobileApp: App {
    @StateObject private var controller = LightController()
    var body: some Scene {
        WindowGroup { ControlPanel(controller: controller) }  // no onQuit on iOS
    }
}
```

There is no built-in server URL: on first launch the panel shows a **Server URL**
field, and the entered value is persisted to `UserDefaults` and reused later.
Edit it any time via the gear button. `UserDefaults` and `URLSession` are
injectable via `LightController.init`, so a test can supply an isolated defaults
suite and a stub session. Add the iOS app as its own target/Xcode project
depending on `LumenCore` + `LumenUI`.

## Run (macOS)

```sh
swift run   # or: make run
```

A light icon appears in the menu bar (no Dock icon — the app runs as an
accessory). Click it for the dropdown.

## Run in the background (no terminal)

Package the app as a `.app` bundle and launch it detached:

```sh
make app       # builds .build/Lumen.app (release + Info.plist + ad-hoc sign)
make install   # copies it to /Applications
open /Applications/Lumen.app
```

`Resources/Info.plist` sets `LSUIElement`, so it runs as a background agent — no
Dock icon, no terminal. Or enable **Launch at login** from the app's settings
(gear button), which registers it via `SMAppService`.

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

- **Lights** — click a row to include/exclude it from control. The dot shows the
  color at its current brightness; `wifi.slash` means the light is unreachable.
- **Color wheel** — angle picks hue, distance from center picks saturation.
  Color is power-neutral: it never turns a light on or off. The bottom-right icon
  resets to white (saturation 0).
- **Brightness** — the single power+level control. 0 turns lights off; any
  positive value turns them on. A light is off exactly when its brightness is 0.
  The left sun icon sets 0% (off), the right sun icon sets 100%.

Writes are debounced (~60 ms) and fan out concurrently to every selected light.
The controller polls every second while awake, greys out the panel and dims the
menu bar icon when the lights are unreachable, and reseeds only on reconnect.

## Notes / next steps

- Set the server URL (the daemon, e.g. `https://lumen.hmblair.com`) via the
  panel's settings (gear button). The raw bridge passthrough at
  `lights.hmblair.com` remains for debugging but the app no longer uses it.
- Scenes (per-light color/brightness programs; sunrise/sunset presets) and
  time-only schedules live on the daemon, managed from the panel's palette
  and calendar screens respectively; while a scene runs, manual control
  pauses (banner + Stop). Scenes are authored in the axis-style curve editor
  (x = time, y = brightness, points carry color; drag the timeline to try
  the scene live, Preview runs it compressed to 15 s and restores the room
  after). Curves render and run as monotone cubic splines — the editor draws
  exactly what the daemon executes.
- A `ControlWidget` could add a quick on/off toggle to Control Center; the color
  wheel has to stay in the menu bar.
