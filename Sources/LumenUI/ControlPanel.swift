// ControlPanel.swift
// The shared control UI: server setup, light picker, HS color wheel, brightness
// slider. Cross-platform and provider-neutral — it depends only on
// LightController and the normalized Light model, never on any vendor detail.
// Each app supplies its own window/menu-bar shell and, optionally, a Quit action
// and a login-item control. No fixed frame here; the shell sizes it.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI
import LumenCore

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

    @State private var hue = 0.08
    @State private var saturation = 0.6
    @State private var brightness = 1.0
    @State private var isSeeding = false

    @State private var urlText = ""
    @State private var bridgeIPText = ""
    @State private var bridgeStatus: String?

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
    @State private var urlStatus: URLStatus = .none
    @State private var checkTask: Task<Void, Never>?

    private enum URLStatus { case none, checking, valid, invalid }

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
                               currentColor: { (hue, saturation, brightness) },
                               onEditScene: { name, scene in
                                   screen = .sceneEditor(SceneEditContext(name: name, scene: scene))
                               })
                case .sceneEditor(let context):
                    runningBanner
                    SceneEditorView(controller: controller,
                                    originalName: context.name,
                                    original: context.scene,
                                    currentColor: { (hue, saturation, brightness) },
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
            urlText = controller.baseURL?.absoluteString ?? ""
            // Keep first-run setup on screen so it doesn't jump to controls the
            // moment a valid URL auto-applies; the user leaves via the gear.
            if !controller.isConfigured { screen = .settings }
            seedFromLiveState()
            // Groups feed the chips on the main screen (scenes/schedules
            // screens reload the library themselves on open).
            Task { await controller.loadLibrary() }
        }
        .onChange(of: controller.selection) { _ in seedFromLiveState() }
        // Reseed only when the controller adopts fresh state (first load or
        // reconnection); steady-state polls don't bump syncToken, so an edit in
        // progress is never overridden.
        .onChange(of: controller.syncToken) { _ in seedFromLiveState() }
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
            RoomListView(controller: controller, dismissToken: dismissEditsToken)
            Divider()

            if controller.selectionIsMixed, let rep = controller.representative {
                Label("Mixed colors — showing \(rep.name). Drag to unify.",
                      systemImage: "circle.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ColorWheel(hue: $hue, saturation: $saturation) {
                controller.applyColor(hue: hue, saturation: saturation)
            }
            .frame(width: 210, height: 210)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            // Dim the wheel itself here; the drop button below dims via its
            // own style's disabled treatment (dimming after the overlay
            // stacked both, greying the button twice).
            .opacity(hasSelection ? 1 : 0.35)
            .overlay(alignment: .bottomTrailing) {
                // White is the center of the HS wheel (saturation 0).
                Button {
                    saturation = 0
                    controller.applyColor(hue: hue, saturation: 0)
                } label: {
                    Image(systemName: "drop.halffull")
                }
                .buttonStyle(HoverIconButtonStyle())
                .help("Reset to white")
            }
            .disabled(!hasSelection)
            .frame(maxWidth: .infinity, alignment: .center)   // center within the panel

            brightnessSlider
        }
        .disabled(!controller.isReachable || controller.running != nil)
        .opacity(controller.isReachable && controller.running == nil ? 1 : 0.4)
    }

    // MARK: - Server configuration

    private var serverSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SERVER URL").font(.caption).foregroundStyle(.secondary)
            TextField("https://lumen.example.com", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: urlText) { _ in checkURL() }
                .overlay(alignment: .trailing) {
                    urlStatusIcon.padding(.trailing, 6)
                }
            if controller.isConfigured {
                bridgeSetup
            }
            if let loginItem {
                Toggle("Launch at login", isOn: Binding(
                    get: loginItem.isEnabled,
                    set: loginItem.setEnabled))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)
            }
            if let onQuit {
                Button { onQuit() } label: {
                    Image(systemName: "power.circle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.red, Color.primary)
                        .font(.title2)
                }
                .buttonStyle(HoverIconButtonStyle())
                .help("Quit")
            }
        }
        .onAppear(perform: checkURL)
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

    @ViewBuilder private var urlStatusIcon: some View {
        switch urlStatus {
        case .none:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .valid:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .invalid:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    /// Auto-apply the field: validate, then probe reachability, driving the
    /// status indicator (spinner -> tick/cross). A well-formed URL is applied
    /// even if unreachable, so the server updates as soon as you finish typing.
    private func checkURL() {
        checkTask?.cancel()
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { urlStatus = .none; return }
        guard let url = normalizedURL(from: urlText) else { urlStatus = .invalid; return }
        urlStatus = .checking
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(400))   // debounce typing
            if Task.isCancelled { return }
            controller.baseURL = url
            let ok = await controller.checkReachable()
            if Task.isCancelled { return }
            urlStatus = ok ? .valid : .invalid
        }
    }

    /// Accept only a well-formed http(s) URL with a host.
    private func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    // MARK: - Seeding

    /// Mirror the wheel and slider onto the representative light's current
    /// hue/sat/brightness. Runs on open and when the selection changes — never
    /// mid-drag, so it won't fight the user (we don't refresh on every write).
    private func seedFromLiveState() {
        guard let light = controller.representative else { return }
        hue = light.hue
        saturation = light.saturation
        // Only flag a seed when the value actually changes, otherwise onChange
        // won't fire and the guard would swallow the user's next edit.
        let newBrightness = light.brightness
        if newBrightness != brightness {
            isSeeding = true
            brightness = newBrightness
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Lumen").font(.headline)
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
                .buttonStyle(HoverIconButtonStyle())
                .help("Scenes")

                Button {
                    screen = screen == .schedules ? .controls : .schedules
                } label: {
                    Image(systemName: screen == .schedules ? "xmark" : "calendar.badge.clock")
                }
                .buttonStyle(HoverIconButtonStyle())
                .help("Schedules")

                Button {
                    urlText = controller.baseURL?.absoluteString ?? ""
                    screen = screen == .settings ? .controls : .settings
                } label: {
                    Image(systemName: screen == .settings ? "xmark" : "gearshape")
                }
                .buttonStyle(HoverIconButtonStyle())
                .help("Settings")
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
                Button { brightness = 0 } label: {
                    Image(systemName: "sun.min")
                }
                .buttonStyle(HoverIconButtonStyle())
                .help("Off")

                Slider(value: $brightness, in: 0...1)
                    .onChange(of: brightness) { _ in
                        if isSeeding { isSeeding = false; return }
                        controller.applyBrightness(brightness)
                    }

                Button { brightness = 1 } label: {
                    Image(systemName: "sun.max.fill")
                }
                .buttonStyle(HoverIconButtonStyle())
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

