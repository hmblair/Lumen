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
curves — with no UI import. `LumenUI` splits into three layers: shared pieces
at its root (the color wheel, the scene editor, and the working-state models —
`WheelState`, `ServerSetupModel`, `ScheduleDraft` — plus the summary
formatting), the macOS menu-bar panel in `Mac/`, and the iOS tab-bar screens
in `Mobile/`. Each platform composes its own screens from the shared pieces,
so the two apps can restyle freely without duplicating any logic. `Lumen` is
the composition root and the only place AppKit appears. Supporting another
light vendor means rewriting the daemon's `bridge.rs` and shipping no app
update at all.

The iOS app (`Apps/iOS/LumenMobileApp.swift` over `MobileRootView`) is a native tab-bar app — Lights, Scenes, Schedules, Settings — with the color wheel and brightness slider docked in a glass card while lights are selected. The Xcode project is generated from `Apps/project.yml` by [xcodegen](https://github.com/yonaskolb/XcodeGen). Put your Apple team ID and device name in an untracked `Makefile.local`:

```make
TEAM_ID := ABCDE12345
DEVICE  := My iPhone
```

Then `make ios` builds a signed release, `make ios-install` puts it on the device, and `make ios-run` also launches it. The device must be paired for development (connect it once and trust this Mac in Xcode).

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
| `make universal` | one binary carrying both architectures |
| `make dist` | universal, signed `.dmg` to hand to someone else |
| `make ios` | generate the Xcode project and build the signed iOS app |
| `make ios-install` | build and install on `DEVICE` |
| `make ios-run` | build, install, and launch on `DEVICE` |
| `make daemon-logs DAEMON_HOST=user@host` | tail the daemon's journal over ssh |
| `make clean` | remove build artifacts |

## Distributing

`make dist` produces `.build/dist/Lumen-<version>.dmg`: a drag-to-Applications
image around a universal build, so one file serves Apple silicon and Intel.
Local builds (`make app`, `make install`) stay native-only and fast — the
architectures are built separately and joined with `lipo`, which needs only the
Command Line Tools, not a full Xcode.

Edit the version in one place, `CFBundleShortVersionString` in
`Resources/Info.plist`. The build stamps `CFBundleVersion` (the commit count)
and `LumenGitRevision` beside it, so Get Info shows the version with a build
number after it and any copy in someone else's hands names the commit it came
from.

Signing is ad-hoc unless told otherwise, which is all a local build needs.
Whether that is enough for someone else depends on how the image travels to
them: the quarantine flag is stamped by the receiving app, so a copy carried on
a USB stick or over `scp` arrives clean and simply opens, while one that comes
by browser, AirDrop, or Messages arrives quarantined — and an ad-hoc signature
can't clear that. A quarantined copy opens only after

```sh
xattr -dr com.apple.quarantine /Applications/Lumen.app
```

To ship one that just opens, sign with a Developer ID and notarize (store the
credentials once with `xcrun notarytool store-credentials`):

```sh
make dist SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
          NOTARY_PROFILE=lumen
```

That path also enables the hardened runtime, which notarization requires, and
staples the ticket to the image so it opens offline.

## Next

A `ControlWidget` could add a quick on/off toggle to Control Center; the color
wheel has to stay in the menu bar.

## License

MIT — see [LICENSE](LICENSE).
