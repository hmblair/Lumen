// Light+Color.swift
// The SwiftUI presentation of a light's color. Kept in HueUI so HueCore stays
// free of any UI dependency (and trivially testable).
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI
import HueCore

extension Light {
    /// Hue/sat at full brightness — the exact color the wheel represents.
    var color: Color {
        Color(hue: hueFraction, saturation: satFraction, brightness: 1)
    }

    /// The row swatch: hue/sat dimmed to the light's current brightness, so it
    /// reads as the color actually being emitted. Off (brightness 0) renders as
    /// black — the swatch's ring keeps it visible.
    var swatchColor: Color {
        Color(hue: hueFraction, saturation: satFraction, brightness: brightnessFraction)
    }
}
