// LumenMobileApp.swift
// iOS shell: the tab-bar root over the shared controller. Polling runs only
// while the app is foreground, driven by the scene phase. All screens live
// in LumenUI/Mobile; this file is the composition root only.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI
import LumenCore
import LumenUI

@main
struct LumenMobileApp: App {
    @StateObject private var controller = LightController()
    @Environment(\.scenePhase) private var scenePhase

    // Qualified: LumenCore.Scene (a light scene) shadows SwiftUI.Scene here.
    var body: some SwiftUI.Scene {
        WindowGroup {
            MobileRootView(controller: controller)
        }
        .onChange(of: scenePhase) {
            scenePhase == .active ? startForeground() : stopForeground()
        }
    }

    /// Adopts fresh state immediately, then keeps polling once a second while
    /// the app is on screen — the same cadence as the Mac panel while open.
    private func startForeground() {
        controller.isForeground = true
        Task { await controller.refresh() }
        controller.startPolling(every: .seconds(1))
    }

    private func stopForeground() {
        controller.isForeground = false
        controller.stopPolling()
    }
}
