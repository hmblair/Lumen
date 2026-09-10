// MobileSettingsScreen.swift
// The iOS settings screen: the server URL (validated live via the shared
// ServerSetupModel) and the daemon's Hue bridge configuration.
// Author: Hamish M. Blair <hmblair@stanford.edu>

#if os(iOS)

import SwiftUI
import LumenCore

struct MobileSettingsScreen: View {
    @ObservedObject var controller: LightController
    @StateObject private var server = ServerSetupModel()

    @State private var bridgeIPText = ""
    @State private var bridgeStatus: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("https://lumen.example.com", text: $server.urlText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        URLStatusIcon(status: server.status)
                    }
                } header: {
                    Text("Server URL")
                }
                if controller.isConfigured {
                    bridgeSection
                }
                Section {
                    LabeledContent("Version", value: SettingsContent.version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { server.adopt(from: controller) }
            .onChange(of: server.urlText) { server.urlEdited(controller) }
            .task {
                await controller.loadBridgeConfig()
                bridgeIPText = controller.bridgeConfig?.bridgeIP ?? ""
            }
        }
    }

    /// The daemon's bridge address: a status row (in-use address, auto vs
    /// manual, reachability) and an override field. Empty = mDNS discovery.
    private var bridgeSection: some View {
        Section {
            if let config = controller.bridgeConfig {
                LabeledContent("Bridge") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(config.bridgeReachable ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text("\(config.activeIP ?? "searching…") · \(config.bridgeIP == nil ? "auto" : "manual")")
                    }
                }
            }
            HStack {
                TextField("auto (mDNS discovery)", text: $bridgeIPText)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                Button("Apply") { applyBridgeIP() }
            }
            if let bridgeStatus {
                Label(bridgeStatus, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Hue Bridge")
        }
    }

    private func applyBridgeIP() {
        let trimmed = bridgeIPText.trimmingCharacters(in: .whitespaces)
        bridgeStatus = nil
        Task {
            bridgeStatus = await controller.setBridgeIP(trimmed.isEmpty ? nil : trimmed)
        }
    }
}

#endif
