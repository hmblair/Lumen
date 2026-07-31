// HueControlPanel.swift
// The shared control UI: bridge setup, light picker, HS color wheel, brightness
// slider, power. Cross-platform — each app supplies its own window/menu-bar
// shell and, optionally, a Quit action. No fixed frame here; the shell sizes it.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI
import HueCore

public struct HueControlPanel: View {
    @ObservedObject private var client: HueClient
    private let onQuit: (() -> Void)?

    @State private var hue = 0.08
    @State private var saturation = 0.6
    @State private var brightness = 1.0
    @State private var isSeeding = false

    @State private var urlText = ""
    @State private var showingSettings = false

    /// - Parameter onQuit: supplied by platforms that can quit (macOS menu bar);
    ///   pass nil on iOS to hide the Quit button.
    public init(client: HueClient, onQuit: (() -> Void)? = nil) {
        self._client = ObservedObject(wrappedValue: client)
        self.onQuit = onQuit
    }

    private var hasSelection: Bool { !client.selection.isEmpty }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            // No bridge yet (or the user opened settings) -> show the editor.
            if client.isConfigured && !showingSettings {
                controls
            } else {
                bridgeSetup
            }
        }
        .padding(14)
        .task {
            urlText = client.baseURL?.absoluteString ?? ""
            if client.isConfigured {
                await client.refresh()
                seedFromLiveState()
            }
        }
        .onChange(of: client.selection) { _ in seedFromLiveState() }
    }

    @ViewBuilder private var controls: some View {
        lightPicker
        Divider()

        if client.selectionIsMixed, let rep = client.representative {
            Label("Mixed colors — showing \(rep.name). Drag to unify.",
                  systemImage: "circle.lefthalf.filled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        ColorWheel(hue: $hue, saturation: $saturation) {
            client.applyColor(hue: hue, saturation: saturation)
        }
        .frame(width: 210, height: 210)
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
        .opacity(hasSelection ? 1 : 0.35)
        .disabled(!hasSelection)
        .frame(maxWidth: .infinity, alignment: .center)   // center within the panel

        brightnessSlider
        if onQuit != nil { footer }
    }

    // MARK: - Bridge configuration

    private var bridgeSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BRIDGE URL").font(.caption).foregroundStyle(.secondary)
            TextField("https://bridge.example.com", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveBridge)
            if let err = client.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Save", action: saveBridge)
                    .buttonStyle(.borderedProminent)
                    .disabled(normalizedURL(from: urlText) == nil)
            }
        }
    }

    private func saveBridge() {
        guard let url = normalizedURL(from: urlText) else { return }
        client.baseURL = url
        showingSettings = false
        Task {
            await client.refresh()
            seedFromLiveState()
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
        guard let light = client.representative else { return }
        hue = light.hueFraction
        saturation = light.satFraction
        // Only flag a seed when the value actually changes, otherwise onChange
        // won't fire and the guard would swallow the user's next edit.
        let newBrightness = light.brightnessFraction
        if newBrightness != brightness {
            isSeeding = true
            brightness = newBrightness
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Hue Control").font(.headline)
            Spacer()
            if client.isConfigured {
                Button {
                    Task { await client.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")

                Button {
                    urlText = client.baseURL?.absoluteString ?? ""
                    showingSettings.toggle()
                } label: {
                    Image(systemName: showingSettings ? "xmark" : "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Bridge settings")
            }
        }
    }

    private var lightPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LIGHTS").font(.caption).foregroundStyle(.secondary)
            if let err = client.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            ForEach(client.lights) { light in
                Button {
                    toggleSelection(light.id)
                } label: {
                    HStack {
                        Image(systemName: client.selection.contains(light.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(client.selection.contains(light.id) ? Color.accentColor : Color.secondary)
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
            if client.brightnessIsMixed, let rep = client.representative {
                Label("Mixed brightness — showing \(rep.name). Drag to unify.",
                      systemImage: "circle.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button { brightness = 0 } label: {
                    Image(systemName: "sun.min")
                }
                .buttonStyle(.borderless)
                .help("Off")

                Slider(value: $brightness, in: 0...1)
                    .onChange(of: brightness) { _ in
                        if isSeeding { isSeeding = false; return }
                        client.applyBrightness(brightness)
                    }

                Button { brightness = 1 } label: {
                    Image(systemName: "sun.max.fill")
                }
                .buttonStyle(.borderless)
                .help("Full brightness")
            }
        }
        .disabled(!hasSelection)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit") { onQuit?() }
                .buttonStyle(.borderless)
        }
    }

    private func toggleSelection(_ id: String) {
        if client.selection.contains(id) {
            client.selection.remove(id)
        } else {
            client.selection.insert(id)
        }
    }
}
