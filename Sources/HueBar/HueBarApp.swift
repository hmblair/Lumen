// HueBarApp.swift
// macOS shell: a menu-bar-only app that hosts the shared HueControlPanel.
// All reusable logic lives in HueCore/HueUI; this file is the composition root
// and the only place AppKit appears.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI
import HueCore
import HueUI

@main
struct HueBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var client = HueClient()

    var body: some Scene {
        MenuBarExtra {
            HueControlPanel(client: client, onQuit: { NSApp.terminate(nil) })
                .frame(width: 280)
        } label: {
            Image(nsImage: statusImage)
        }
        .menuBarExtraStyle(.window)
    }

    /// The menu bar icon. Palette rendering keeps the bulb neutral (Primary =
    /// label color) and tints only the accent rays from the representative light
    /// — the same hue/sat/brightness that drives its swatch. A colored NSImage
    /// must set `isTemplate = false`, otherwise the menu bar flattens it.
    private var statusImage: NSImage {
        let base = NSImage(systemSymbolName: "warninglight.fill",
                           accessibilityDescription: "Hue lights")
            ?? NSImage(systemSymbolName: "lightbulb.fill",
                       accessibilityDescription: "Hue lights")!

        guard let light = client.representative, light.on else {
            // Off / nothing selected: monochrome, adapts to the menu bar.
            base.isTemplate = true
            return base
        }

        // Floor the value so a dim light's rays stay visible in the menu bar.
        let value = max(0.55, light.brightnessFraction)
        let accent = NSColor(hue: light.hueFraction,
                             saturation: light.satFraction,
                             brightness: value, alpha: 1)
        let config = NSImage.SymbolConfiguration(paletteColors: [.labelColor, accent])
        let tinted = base.withSymbolConfiguration(config) ?? base
        tinted.isTemplate = false
        return tinted
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
    }
}
