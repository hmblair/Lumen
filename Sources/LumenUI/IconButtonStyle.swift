// IconButtonStyle.swift
// The house style for icon/symbol buttons, one per platform behind one name.
// macOS: secondary at rest, brightening with a subtle rounded background on
// hover — the affordance a pointer expects. iOS: a circular Liquid Glass
// button at a full touch target — the affordance a finger expects.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        HoverIcon(configuration: configuration)
        #else
        GlassIcon(configuration: configuration)
        #endif
    }

    #if os(macOS)
    private struct HoverIcon: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(hovering && isEnabled ? Color.primary : Color.secondary)
                .opacity(isEnabled ? 1 : 0.35)
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
    #else
    /// The circle is fixed at 36 pt — comfortably tappable — regardless of
    /// the glyph inside it.
    static let touchDiameter: CGFloat = 36

    private struct GlassIcon: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .fontWeight(.medium)
                .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: IconButtonStyle.touchDiameter,
                       height: IconButtonStyle.touchDiameter)
                .glassEffect(.regular.interactive(), in: .circle)
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .contentShape(Circle())
        }
    }
    #endif
}
