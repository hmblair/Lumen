// MobileRootView.swift
// The iOS app's root: four tabs over the shared LightController. The wheel/
// slider working color is owned here so the Lights screen edits it and the
// Scenes screen reads it (save-as-scene, editor seeding), matching the macOS
// panel's single working color.
// Author: Hamish M. Blair <hmblair@stanford.edu>

#if os(iOS)

import SwiftUI
import LumenCore

public struct MobileRootView: View {
    @ObservedObject private var controller: LightController
    @StateObject private var wheel = WheelState()

    public init(controller: LightController) {
        self._controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        TabView {
            Tab("Lights", systemImage: "lightbulb.fill") {
                MobileLightsScreen(controller: controller,
                                   rooms: controller.rooms,
                                   wheel: wheel)
            }
            Tab("Scenes", systemImage: "paintpalette.fill") {
                MobileScenesScreen(controller: controller, wheel: wheel)
            }
            Tab("Schedules", systemImage: "calendar.badge.clock") {
                MobileSchedulesScreen(controller: controller)
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                MobileSettingsScreen(controller: controller)
            }
        }
        .onAppear { wheel.seed(from: controller) }
        .onChange(of: controller.selection) { wheel.seed(from: controller) }
        // Reseed only when the controller adopts fresh state (first load or
        // reconnection); steady-state polls don't bump syncToken, so an edit
        // in progress is never overridden.
        .onChange(of: controller.syncToken) { wheel.seed(from: controller) }
        .task { await controller.loadLibrary() }
    }
}

/// The banner shown while a scene owns the lights (schedule-wins): the daemon
/// would 409 manual writes, so the UI says so up front and offers Stop.
struct RunningSceneBanner: View {
    @ObservedObject var controller: LightController

    var body: some View {
        if let running = controller.running {
            HStack {
                Label(label(running), systemImage: "sparkles")
                    .font(.subheadline)
                Spacer()
                Button("Stop") {
                    Task { await controller.stopScene() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func label(_ running: RunningInfo) -> String {
        let scene = "'\(running.scene)' running"
        guard running.ends > Date() else { return scene }
        let time = running.ends.formatted(date: .omitted, time: .shortened)
        return "\(scene) until \(time)"
    }
}

/// The row shown while the lights are unreachable.
struct UnreachableBanner: View {
    @ObservedObject var controller: LightController

    var body: some View {
        if !controller.isReachable {
            Label(controller.lastError ?? "Can't reach the lights",
                  systemImage: "wifi.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(.orange)
        }
    }
}

/// Placeholder for screens that need a configured server.
struct UnconfiguredPlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Server", systemImage: "lightbulb.slash")
        } description: {
            Text("Enter your Lumen server's URL in Settings.")
        }
    }
}

#endif
