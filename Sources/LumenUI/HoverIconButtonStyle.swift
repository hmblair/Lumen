// HoverIconButtonStyle.swift
// The house style for icon/symbol buttons: secondary at rest, brightening
// with a subtle rounded background on hover, and a small press scale — so
// every tappable glyph (suns, drops, plus/minus, pencils, ...) reads as
// clickable and reacts consistently.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI

struct HoverIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverIcon(configuration: configuration)
    }

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
}
