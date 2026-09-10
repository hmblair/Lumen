// ColorWheel.swift
// HS color wheel: angle -> hue, radius -> saturation. Brightness lives on a
// separate slider so the wheel stays a pure hue/sat picker. Cross-platform.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI

struct ColorWheel: View {
    @Binding var hue: Double        // 0...1
    @Binding var saturation: Double // 0...1
    var onChange: () -> Void

    private var ringColors: [Color] {
        stride(from: 0.0, through: 1.0, by: 1.0 / 12.0)
            .map { Color(hue: $0, saturation: 1, brightness: 1) }
    }

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            let center = CGPoint(x: radius, y: radius)
            // The thumb scales with the wheel (20 pt at the classic 210 pt
            // wheel), floored so it stays visible on small wheels.
            let thumbSize = max(12, radius * 20 / 105)

            ZStack {
                AngularGradient(gradient: Gradient(colors: ringColors), center: .center)
                    .clipShape(Circle())
                RadialGradient(
                    gradient: Gradient(colors: [.white, .clear]),
                    center: .center, startRadius: 0, endRadius: radius)
                    .clipShape(Circle())
                    .allowsHitTesting(false)

                Circle()
                    .fill(Color(hue: hue, saturation: saturation, brightness: 1))
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(Circle().stroke(.white, lineWidth: thumbSize * 0.15))
                    .shadow(radius: 1)
                    .position(thumb(center: center, radius: radius))
            }
            .contentShape(Circle())
            .gesture(overridingScroll:
                DragGesture(minimumDistance: 0)
                    .onChanged { update($0.location, center: center, radius: radius) }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func thumb(center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = hue * 2 * .pi
        let r = saturation * radius
        return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
    }

    private func update(_ location: CGPoint, center: CGPoint, radius: CGFloat) {
        let dx = location.x - center.x
        let dy = location.y - center.y
        var angle = atan2(dy, dx)
        if angle < 0 { angle += 2 * .pi }
        hue = angle / (2 * .pi)
        saturation = min(1, hypot(dx, dy) / radius)
        onChange()
    }
}

/// The HS wheel with its reset-to-white drop button as one reusable unit:
/// the button's icon size and diagonal position derive from the diameter,
/// so every wheel in the app carries the same affordance at any scale.
/// Dim-on-disable is handled here and applies to the wheel only — the
/// button dims via its own style's disabled treatment, so the two never
/// stack.
struct ResettableColorWheel: View {
    @Binding var hue: Double
    @Binding var saturation: Double
    let diameter: CGFloat
    var onChange: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        // 16.25 pt at the main panel's 210 pt wheel, floored at tappable.
        let iconSize = max(11, diameter * 16.25 / 210)
        // Center the button on the 45° diagonal, just clear of the rim. The
        // button's visual footprint differs per platform: macOS pads the
        // glyph by ~3 pt for its hover background, iOS wraps it in a fixed
        // glass circle.
        #if os(macOS)
        let buttonRadius = iconSize / 2 + 7
        #else
        let buttonRadius = IconButtonStyle.touchDiameter / 2 + 4
        #endif
        let offset = (diameter / 2 + buttonRadius) / 2.0.squareRoot()
        ColorWheel(hue: $hue, saturation: $saturation, onChange: onChange)
            .frame(width: diameter, height: diameter)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.35)
            .overlay {
                // White is the center of the HS wheel (saturation 0).
                Button {
                    saturation = 0
                    onChange()
                } label: {
                    Image(systemName: "drop.halffull")
                        .font(.system(size: iconSize))
                }
                .buttonStyle(IconButtonStyle())
                .offset(x: offset, y: offset)
                .help("Reset to white")
            }
    }
}
