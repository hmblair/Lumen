// ErrorBanner.swift
// The shared inline error message: orange, compact, dismissable with a
// small x. Bound to the owning screen's error state, so dismissing clears
// it at the source; layout is left to the caller (it's just a label + x).
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI

struct ErrorBanner: View {
    @Binding var message: String?

    var body: some View {
        if let message {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button {
                    self.message = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(HoverIconButtonStyle())
                .help("Dismiss")
            }
        }
    }
}
