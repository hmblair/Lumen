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
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .shadow(radius: 1)
                    .position(thumb(center: center, radius: radius))
            }
            .contentShape(Circle())
            .gesture(
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
