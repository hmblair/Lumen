// PlatformShims.swift
// Tiny cross-platform adapters so the shared views compile on both macOS and
// iOS without scattering #if blocks through view code.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI

extension View {
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
