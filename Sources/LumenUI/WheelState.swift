// WheelState.swift
// The wheel/slider working color, shared by every shell: what the color
// wheel and brightness slider currently show, seeded from the representative
// light and pushed to the controller on user edits. One implementation so
// the macOS panel and the iOS screens can't drift apart on seeding rules.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI
import LumenCore

@MainActor
final class WheelState: ObservableObject {
    @Published var hue = 0.08
    @Published var saturation = 0.6
    @Published var brightness = 1.0

    /// True while `brightness` was set by a seed rather than the user, so the
    /// slider's next onChange doesn't echo an adopted value back as a write.
    private var isSeeding = false

    /// The current values as a tuple, for "save this color as a scene" and
    /// for seeding new scene-editor curves.
    var current: (hue: Double, saturation: Double, level: Double) {
        (hue, saturation, brightness)
    }

    /// Mirror the wheel and slider onto the representative light's current
    /// hue/sat/brightness. Runs on open and when the selection or adopted
    /// state changes — never mid-drag, so it won't fight the user.
    func seed(from controller: LightController) {
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

    /// The slider's onChange handler: forwards a user edit to the lights, and
    /// swallows the one change a seed produced.
    func brightnessEdited(_ controller: LightController) {
        if isSeeding {
            isSeeding = false
            return
        }
        controller.applyBrightness(brightness)
    }

    /// The wheel's onChange handler.
    func colorEdited(_ controller: LightController) {
        controller.applyColor(hue: hue, saturation: saturation)
    }
}
