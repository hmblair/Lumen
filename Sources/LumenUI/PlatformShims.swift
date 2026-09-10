// PlatformShims.swift
// Tiny cross-platform adapters so the shared views compile on both macOS and
// iOS without scattering #if blocks through view code.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI

extension View {
    /// Attach `gesture` so it wins over an enclosing ScrollView on iOS,
    /// where scrolling otherwise steals the drag. macOS has no enclosing
    /// scroll views in this app, so the normal attachment keeps gesture
    /// precedence there unchanged.
    @ViewBuilder
    func gesture(overridingScroll gesture: some Gesture) -> some View {
        #if os(macOS)
        self.gesture(gesture)
        #else
        highPriorityGesture(gesture)
        #endif
    }

    /// Run `action` when the user presses Escape. On iOS there is no Escape
    /// key (`onExitCommand` doesn't exist there); tap-outside dismissal
    /// covers the same intent, so this is a no-op.
    @ViewBuilder
    func onEscape(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}
