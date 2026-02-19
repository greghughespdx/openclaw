import NetworkExtension
import SwiftUI

struct VPNTunnelSettingsView: View {
    @Environment(TunnelManager.self) private var tunnelManager: TunnelManager

    @State private var serverEndpoint: String = ""
    @State private var serverPublicKey: String = ""
    @State private var isConfiguring: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if tunnelManager.isConfigured {
                Section("Status") {
                    LabeledContent("Connection") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 8, height: 8)
                            Text(tunnelManager.tunnelStatus.description.capitalized)
                        }
                    }

                    if tunnelManager.tunnelStatus == .connected {
                        Button("Disconnect", role: .destructive) {
                            tunnelManager.disconnect()
                        }
                    } else {
                        Button("Connect") {
                            Task {
                                do {
                                    try await tunnelManager.connect()
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                            }
                        }
                        .disabled(isConnecting)
                    }
                }

                Section("Configuration") {
                    if let publicKey = tunnelManager.clientPublicKey {
                        LabeledContent("Client Public Key") {
                            Text(publicKey)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = publicKey
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                    }

                    Button("Reconfigure", role: .destructive) {
                        Task {
                            await tunnelManager.loadFromSystem()
                        }
                    }
                }
            } else {
                Section {
                    TextField("Server Endpoint", text: $serverEndpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .placeholder(when: serverEndpoint.isEmpty) {
                            Text("example: home.example.com:51820")
                                .foregroundStyle(.secondary)
                        }

                    TextField("Server Public Key", text: $serverPublicKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 14, design: .monospaced))
                        .placeholder(when: serverPublicKey.isEmpty) {
                            Text("Base64 encoded WireGuard public key")
                                .foregroundStyle(.secondary)
                        }

                    Button {
                        Task {
                            await configureVPN()
                        }
                    } label: {
                        if isConfiguring {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                Text("Configuring…")
                            }
                        } else {
                            Text("Generate Keys & Configure")
                        }
                    }
                    .disabled(isConfiguring || !isInputValid)

                    if let error = errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Setup")
                } footer: {
                    Text(
                        "Configure a WireGuard VPN tunnel to maintain a persistent connection to your gateway. "
                            + "Enter your gateway's WireGuard endpoint and public key, then tap Configure to generate client keys."
                    )
                }
            }

            Section {
                Text(
                    "The VPN tunnel allows OpenClaw to maintain a persistent encrypted connection to the gateway, "
                        + "even when the app is backgrounded. iOS gives Network Extensions special background privileges."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } header: {
                Text("About")
            }
        }
        .navigationTitle("VPN Tunnel")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusColor: Color {
        switch tunnelManager.tunnelStatus {
        case .connected:
            .green
        case .connecting, .reasserting:
            .orange
        case .disconnected, .invalid:
            .secondary.opacity(0.35)
        case .disconnecting:
            .orange
        @unknown default:
            .secondary.opacity(0.35)
        }
    }

    private var isConnecting: Bool {
        tunnelManager.tunnelStatus == .connecting || tunnelManager.tunnelStatus == .reasserting
    }

    private var isInputValid: Bool {
        !serverEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !serverPublicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    private func configureVPN() async {
        errorMessage = nil
        isConfiguring = true
        defer { isConfiguring = false }

        do {
            try await tunnelManager.configure(
                serverEndpoint: serverEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                serverPublicKey: serverPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - View Helpers

extension View {
    @ViewBuilder
    func placeholder<Content: View>(
        when shouldShow: Bool,
        @ViewBuilder placeholder: () -> Content
    ) -> some View {
        if shouldShow {
            ZStack(alignment: .leading) {
                placeholder()
                self
            }
        } else {
            self
        }
    }
}
