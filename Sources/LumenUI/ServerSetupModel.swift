// ServerSetupModel.swift
// The server URL field's working state: validation, debounced reachability
// probe, and the status the field's indicator renders. One implementation
// shared by the macOS settings screen and the iOS one.
// Author: Hamish M. Blair <hmblair@stanford.edu>

import SwiftUI
import LumenCore

@MainActor
final class ServerSetupModel: ObservableObject {
    enum URLStatus { case none, checking, valid, invalid }

    @Published var urlText = ""
    @Published private(set) var status: URLStatus = .none

    private var checkTask: Task<Void, Never>?

    /// Adopt the controller's current URL into the field (on screen open).
    func adopt(from controller: LightController) {
        urlText = controller.baseURL?.absoluteString ?? ""
    }

    /// Auto-apply the field: validate, then probe reachability, driving the
    /// status indicator (spinner -> tick/cross). A well-formed URL is applied
    /// even if unreachable, so the server updates as soon as you finish typing.
    func urlEdited(_ controller: LightController) {
        checkTask?.cancel()
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { status = .none; return }
        guard let url = Self.normalizedURL(from: urlText) else { status = .invalid; return }
        status = .checking
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(400))   // debounce typing
            if Task.isCancelled { return }
            controller.baseURL = url
            let ok = await controller.checkReachable()
            if Task.isCancelled { return }
            status = ok ? .valid : .invalid
        }
    }

    /// Accept only a well-formed http(s) URL with a host.
    static func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }
}

/// The field's trailing status indicator, shared by both platforms.
struct URLStatusIcon: View {
    let status: ServerSetupModel.URLStatus

    var body: some View {
        switch status {
        case .none:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .valid:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .invalid:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}
