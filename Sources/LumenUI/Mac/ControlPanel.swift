// ControlPanel.swift
// The macOS menu-bar panel UI: server setup, light picker, HS color wheel,
// brightness slider, and the panel's own screen switching. Provider-neutral —
// it depends only on LightController and the normalized Light model. The iOS
// app has its own screens (Mobile/); the working state they share with this
// panel (WheelState, ServerSetupModel) lives in the module root.
// Author: Hamish M. Blair <hmblair@stanford.edu>

#if os(macOS)

import SwiftUI
import LumenCore
import AppKit

/// Injected "launch at login" control. The implementation is platform-specific
/// (macOS uses SMAppService), so LumenUI stays free of ServiceManagement.
public struct LoginItem {
    public var isEnabled: () -> Bool
    public var setEnabled: (Bool) -> Void

    public init(isEnabled: @escaping () -> Bool, setEnabled: @escaping (Bool) -> Void) {
        self.isEnabled = isEnabled
        self.setEnabled = setEnabled
    }
}

public struct ControlPanel: View {
    @ObservedObject private var controller: LightController
    private let onQuit: (() -> Void)?
    private let loginItem: LoginItem?

    @StateObject private var wheel = WheelState()
    @StateObject private var server = ServerSetupModel()

    @State private var bridgeIPText = ""
    @State private var bridgeStatus: String?
    /// Daemon settings are global — every client shares them — so they sit
    /// behind a collapsed disclosure to keep casual fingers off.
    @State private var showDaemonSettings = false

    /// Single source of truth for navigation — one current screen, so
    /// contradictory combinations (an open editor under a closed section)
    /// are unrepresentable. The scene editor belongs to the scenes section.
    private enum Screen: Equatable {
        case controls
        case settings
        case scenes
        case schedules
        case sceneEditor(SceneEditContext)

        var inScenes: Bool {
            if case .sceneEditor = self { return true }
            return self == .scenes
        }
    }

    private struct SceneEditContext: Identifiable, Equatable {
        let id = UUID()
        var name: String?
        var scene: LumenCore.Scene?
    }

    @State private var screen: Screen = .controls
    /// Bumped on background clicks anywhere in the panel; RoomListView
    /// dismisses its inline edits on change.
    @State private var dismissEditsToken = 0

    /// - Parameters:
    ///   - onQuit: supplied by platforms that can quit (macOS menu bar); pass
    ///     nil on iOS to hide the Quit button.
    ///   - loginItem: supplied by platforms with a login-item API; pass nil to
    ///     hide the "Launch at login" toggle.
    public init(controller: LightController,
                onQuit: (() -> Void)? = nil,
                loginItem: LoginItem? = nil) {
        self._controller = ObservedObject(wrappedValue: controller)
        self.onQuit = onQuit
        self.loginItem = loginItem
    }

    private var hasSelection: Bool { !controller.selection.isEmpty }

    /// Color is editable only when something is selected and every selected
    /// light is on — an off bulb can't store a color, so the wheel greys
    /// out rather than accepting a change the bridge would revert.
    private var colorEnabled: Bool {
        hasSelection && !controller.selectionHasOffLights
    }

    private var isEditingScene: Bool {
        if case .sceneEditor = screen { return true }
        return false
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if !controller.isConfigured || screen == .settings {
                serverSetup
            } else {
                switch screen {
                case .scenes:
                    runningBanner
                    ScenesView(controller: controller,
                               currentColor: { wheel.current },
                               onEditScene: { name, scene in
                                   screen = .sceneEditor(SceneEditContext(name: name, scene: scene))
                               })
                case .sceneEditor(let context):
                    runningBanner
                    SceneEditorView(controller: controller,
                                    originalName: context.name,
                                    original: context.scene,
                                    currentColor: { wheel.current },
                                    onClose: { screen = .scenes })
                        .id(context.id)   // fresh editor state per open
                case .schedules:
                    runningBanner
                    SchedulesView(controller: controller)
                case .controls, .settings:
                    controls
                }
            }
        }
        .padding(14)
        // The axis canvas needs more room than the control column.
        .frame(width: isEditingScene ? 420 : 280)
        .contentShape(Rectangle())
        // A click on any non-control area of the panel dismisses inline
        // edits (consumed clicks — buttons, sliders, fields — don't reach
        // this, which is exactly right: clicking inside an edit field keeps
        // it open).
        .onTapGesture { dismissEditsToken &+= 1 }
        .onAppear {
            server.adopt(from: controller)
            // Keep first-run setup on screen so it doesn't jump to controls the
            // moment a valid URL auto-applies; the user leaves via the gear.
            if !controller.isConfigured { screen = .settings }
            wheel.seed(from: controller)
            // Groups feed the chips on the main screen (scenes/schedules
            // screens reload the library themselves on open).
            Task { await controller.loadLibrary() }
        }
        .onChange(of: controller.selection) { _ in wheel.seed(from: controller) }
        // Reseed only when the controller adopts fresh state (first load or
        // reconnection); steady-state polls don't bump syncToken, so an edit in
        // progress is never overridden.
        .onChange(of: controller.syncToken) { _ in wheel.seed(from: controller) }
    }

    /// While a scene runs, manual control pauses (schedule-wins): the daemon
    /// would 409 the writes anyway, so the UI says so up front.
    @ViewBuilder private var runningBanner: some View {
        if let running = controller.running {
            HStack {
                Label(runningLabel(running), systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") {
                    Task { await controller.stopScene() }
                }
                .controlSize(.small)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
        }
    }

    private func runningLabel(_ running: RunningInfo) -> String {
        let scene = "'\(running.scene)' running"
        guard running.ends > Date() else { return scene }
        let time = running.ends.formatted(date: .omitted, time: .shortened)
        return "\(scene) until \(time)"
    }

    @ViewBuilder private var controls: some View {
        if !controller.isReachable {
            Label(controller.lastError ?? "Can't reach the lights",
                  systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        runningBanner
        // Everything that acts on lights is disabled and dimmed while the lights
        // are unreachable (writes would silently fail) or while a scene owns
        // them (writes would 409). The banner, header, and Quit stay usable.
        Group {
            // Room UI insertion point (option B: sectioned list). Option A
            // (chips + flat list) lives at commit 2963c67 if it's ever
            // wanted back.
            RoomListView(controller: controller, rooms: controller.rooms,
                         dismissToken: dismissEditsToken)
            Divider()

            if controller.selectionIsMixed, let rep = controller.representative {
                Label("Mixed colors — showing \(rep.name). Drag to unify.",
                      systemImage: "circle.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ResettableColorWheel(hue: $wheel.hue, saturation: $wheel.saturation, diameter: 210) {
                wheel.colorEdited(controller)
            }
            .disabled(!colorEnabled)
            .frame(maxWidth: .infinity, alignment: .center)   // center within the panel

            brightnessSlider
        }
        .disabled(!controller.isReachable || controller.running != nil)
        .opacity(controller.isReachable && controller.running == nil ? 1 : 0.4)
    }

    // MARK: - Server configuration

    private var serverSetup: some View {
        // Two groups: this app's own settings (server URL, launch at login),
        // then the daemon's (bridge address) — settings that live on the box
        // and are shared by every client.
        VStack(alignment: .leading, spacing: 8) {
            Text("SERVER URL").font(.caption).foregroundStyle(.secondary)
            TextField("https://lumen.example.com", text: $server.urlText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: server.urlText) { _ in server.urlEdited(controller) }
                .overlay(alignment: .trailing) {
                    URLStatusIcon(status: server.status).padding(.trailing, 6)
                }
            if let loginItem {
                Toggle("Launch at login", isOn: Binding(
                    get: loginItem.isEnabled,
                    set: loginItem.setEnabled))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)
            }
            if controller.isConfigured {
                Divider()
                Button {
                    withAnimation { showDaemonSettings.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .rotationEffect(.degrees(showDaemonSettings ? 90 : 0))
                        Text("DAEMON SETTINGS").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if showDaemonSettings {
                    bridgeSetup
                }
            }
            HStack {
                Text("Version \(SettingsContent.version)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let onQuit {
                    Button("Quit") { onQuit() }
                        .controlSize(.small)
                }
            }
        }
        .onAppear { server.urlEdited(controller) }
    }

    /// The daemon's bridge address: a status line (in-use address, auto vs
    /// manual, reachability) and an override field. Empty = mDNS discovery.
    private var bridgeSetup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HUE BRIDGE").font(.caption).foregroundStyle(.secondary)
            if let config = controller.bridgeConfig {
                HStack(spacing: 5) {
                    Circle()
                        .fill(config.bridgeReachable ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text("\(config.activeIP ?? "searching…") · \(config.bridgeIP == nil ? "auto" : "manual")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                TextField("auto (mDNS discovery)", text: $bridgeIPText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { applyBridgeIP() }
                Button("Apply") { applyBridgeIP() }
                    .controlSize(.small)
            }
            if let bridgeStatus {
                Text(bridgeStatus).font(.caption2).foregroundStyle(.orange)
            }
        }
        .task {
            await controller.loadBridgeConfig()
            bridgeIPText = controller.bridgeConfig?.bridgeIP ?? ""
        }
    }

    private func applyBridgeIP() {
        let trimmed = bridgeIPText.trimmingCharacters(in: .whitespaces)
        bridgeStatus = nil
        Task {
            bridgeStatus = await controller.setBridgeIP(trimmed.isEmpty ? nil : trimmed)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Lumen").font(.headline)
                // The provider, greyed and 25% smaller than the title:
                // vendor identity is the daemon's business, so the app only
                // ever names it cosmetically.
                Text("·").font(.headline).foregroundStyle(.secondary)
                Text("Philips Hue")
                    .font(.system(size: headlinePointSize * 0.75, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if controller.isConfigured {
                // No refresh button: polls adopt state continuously, so the
                // panel is never stale by more than a poll interval.

                // Tight spacing: the hover style pads each icon by 3pt for
                // its hover background, so the visual gap matches the old
                // borderless layout.
                HStack(spacing: 2) {
                    headerIcons
                }
            }
        }
    }

    // Each section icon becomes an x while its section is open; the scenes
    // x also closes the editor (it's a sub-screen).
    @ViewBuilder private var headerIcons: some View {
                Button {
                    screen = screen.inScenes ? .controls : .scenes
                } label: {
                    Image(systemName: screen.inScenes ? "xmark" : "paintpalette")
                }
                .buttonStyle(IconButtonStyle())
                .help("Scenes")

                Button {
                    screen = screen == .schedules ? .controls : .schedules
                } label: {
                    Image(systemName: screen == .schedules ? "xmark" : "calendar.badge.clock")
                }
                .buttonStyle(IconButtonStyle())
                .help("Schedules")

                Button {
                    server.adopt(from: controller)
                    screen = screen == .settings ? .controls : .settings
                } label: {
                    Image(systemName: screen == .settings ? "xmark" : "gearshape")
                }
                .buttonStyle(IconButtonStyle())
                .help("Settings")
    }

    /// The platform's headline size, so the provider suffix scales from
    /// whatever "Lumen" actually renders at.
    private var headlinePointSize: CGFloat {
        NSFont.preferredFont(forTextStyle: .headline).pointSize
    }

    private var brightnessSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            if controller.brightnessIsMixed, let rep = controller.representative {
                Label("Mixed brightness — showing \(rep.name). Drag to unify.",
                      systemImage: "circle.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button { wheel.brightness = 0 } label: {
                    Image(systemName: "sun.min")
                }
                .buttonStyle(IconButtonStyle())
                .help("Off")

                Slider(value: $wheel.brightness, in: 0...1)
                    .onChange(of: wheel.brightness) { _ in
                        wheel.brightnessEdited(controller)
                    }

                Button { wheel.brightness = 1 } label: {
                    Image(systemName: "sun.max.fill")
                }
                .buttonStyle(IconButtonStyle())
                .help("Full brightness")
            }
        }
        .disabled(!hasSelection)
    }

    private func toggleSelection(_ id: String) {
        if controller.selection.contains(id) {
            controller.selection.remove(id)
        } else {
            controller.selection.insert(id)
        }
    }
}

#endif
