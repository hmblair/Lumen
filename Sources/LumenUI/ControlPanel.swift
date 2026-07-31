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
    @State private var showingSettings = false
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

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            // Not configured yet (or the user opened settings) -> show the editor.
            if controller.isConfigured && !showingSettings {
                controls
            } else {
                serverSetup
            }
        }
        .padding(14)
        .onAppear {
            urlText = controller.baseURL?.absoluteString ?? ""
            // Keep first-run setup on screen so it doesn't jump to controls the
            // moment a valid URL auto-applies; the user leaves via the gear.
            if !controller.isConfigured { showingSettings = true }
            seedFromLiveState()
        }
        .onChange(of: controller.selection) { _ in seedFromLiveState() }
        // Reseed only when the controller adopts fresh state (first load or
        // reconnection); steady-state polls don't bump syncToken, so an edit in
        // progress is never overridden.
        .onChange(of: controller.syncToken) { _ in seedFromLiveState() }
    }

    @ViewBuilder private var controls: some View {
        if !controller.isReachable {
            Label(controller.lastError ?? "Can't reach the lights",
                  systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        // Everything that acts on lights is disabled and dimmed while the lights
        // are unreachable — those actions would silently fail. The banner, header
        // (refresh/settings) and Quit stay usable.
        Group {
            lightPicker
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
            .opacity(hasSelection ? 1 : 0.35)
            .disabled(!hasSelection)
            .frame(maxWidth: .infinity, alignment: .center)   // center within the panel

            brightnessSlider
        }
        .disabled(!controller.isReachable)
        .opacity(controller.isReachable ? 1 : 0.4)
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
                Button {
                    Task { await controller.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")

                Button {
                    urlText = controller.baseURL?.absoluteString ?? ""
                    showingSettings.toggle()
                } label: {
                    Image(systemName: showingSettings ? "xmark" : "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
        }
    }

    private var lightPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LIGHTS").font(.caption).foregroundStyle(.secondary)
            if controller.lights.isEmpty {
                Text(controller.isReachable ? "No lights found" : "Not connected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(controller.lights) { light in
                Button {
                    toggleSelection(light.id)
                } label: {
                    HStack {
                        Image(systemName: controller.selection.contains(light.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(controller.selection.contains(light.id) ? Color.accentColor : Color.secondary)
                        Text(light.name)
                        Spacer()
                        Text("\(light.brightnessPercent)%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Circle()
                            .fill(light.swatchColor)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.75))
                        if !light.reachable {
                            Image(systemName: "wifi.slash")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
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

/// An icon button that reacts to hover — brightening and showing a subtle
/// background — so tappable icons (the brightness sun icons) read as clickable.
private struct HoverIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverIcon(configuration: configuration)
    }

    private struct HoverIcon: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.12 : 0))
                )
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
                .contentShape(Rectangle())
        }
    }
}
