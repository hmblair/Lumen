# Lumen

A menu-bar smart-light controller for macOS: rooms, an HS color wheel, a
brightness slider, and scheduled scenes. The app talks to the
[Lumen daemon](daemon/README.md), which owns every vendor detail — all values
are `0…1` on the wire, so nothing here is provider-specific.

```
Lumen.app / iOS ── https://lumen.example.com (your reverse proxy)
                        └── lumen-daemon ── Philips Hue bridge
```

## Quickstart

```sh
make install                  # release build, .app bundle, copy to /Applications
open /Applications/Lumen.app
```

A light icon appears in the menu bar — no Dock icon, no terminal
(`LSUIElement` in `Resources/Info.plist`). Click it and enter your daemon's URL
in the **Server URL** field; it is validated as you type and remembered across
launches. The gear button reopens it later, and also holds **Launch at login**
and the daemon's Hue bridge address.

`make run` runs it from the terminal instead, for development.

## The panel

- **Rooms** — the light list, grouped into sections. Click a light's circle to
  include it in manual control, or a room's tick to take all of it. `+` adds a
  room, `−` removes one (its lights stay, unassigned), double-click a room or
  light name to rename, and drag a light between sections to move it. Rooms
  live on the daemon, so every client sees the same layout.
- **Color wheel** — angle picks hue, distance from center picks saturation.
  It never turns a light on or off, and greys out when any selected light is
  off, since an off bulb can't store a color. The corner button resets to white.
- **Brightness** — the single power+level control: 0 turns lights off, any
  positive value turns them on. The sun icons jump to 0% and 100%.
- **Scenes** (palette icon) — per-light color/brightness programs. Save the
  current color as one, or author a curve in the axis editor: x = time,
  y = brightness, each point carrying its own color. Drag the timeline to try
  it live; **Preview** runs it compressed to 15 s and restores the room after.
  Curves draw and run as the same monotone cubic splines the daemon executes.
- **Schedules** (calendar icon) — fire a scene at a wall-clock time, at
  sunrise, or at sunset; on chosen weekdays or once on a date.

While a scene runs, manual control pauses (schedule-wins) and a banner offers
**Stop**. Writes are debounced (~60 ms) and fan out concurrently, collapsing to
one atomic group command when the selection is exactly a room. Polls adopt
daemon state every second, so a change made on another device shows up here;
lights this client just wrote are exempt for 1.5 s so a poll can't clobber a
drag in flight.

## Package layout

| Target | Kind | Depends on | Platform |
|--------|------|------------|----------|
| `LumenCore` | library | Foundation, Combine | any — no UI |
| `LumenUI` | library | LumenCore, SwiftUI | macOS + iOS |
| `Lumen` | executable | LumenCore, LumenUI | macOS menu-bar shell |

`LumenCore` holds the model and networking — lights, rooms, scenes, schedules,
curves — with no UI import. `LumenUI` holds the cross-platform SwiftUI views,
including the reusable `ControlPanel`. `Lumen` is the composition root and the
only place AppKit appears. Supporting another light vendor means rewriting the
daemon's `bridge.rs` and shipping no app update at all.

An iOS app is a new `@main` plus a window over the same panel:

```swift
@main
struct LumenMobileApp: App {
    @StateObject private var controller = LightController()
    var body: some Scene {
        WindowGroup { ControlPanel(controller: controller) }  // no onQuit on iOS
    }
}
```

`UserDefaults` and `URLSession` are injectable via `LightController.init`, so a
test can supply an isolated defaults suite and a stub session.

## Make targets

| Target | Does |
|--------|------|
| `make` / `make build` | debug build |
| `make release` | optimized build |
| `make run` | run in the terminal (dev) |
| `make app` (alias `bundle`) | build the `.app` bundle |
| `make install` | build the bundle and copy it to `/Applications` |
| `make daemon-logs DAEMON_HOST=user@host` | tail the daemon's journal over ssh |
| `make clean` | remove build artifacts |

## Next

A `ControlWidget` could add a quick on/off toggle to Control Center; the color
wheel has to stay in the menu bar.

## License

MIT — see [LICENSE](LICENSE).
