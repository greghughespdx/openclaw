import Combine
import Foundation
import NetworkExtension
import os
import Security
import SwiftUI

@MainActor
@Observable
final class TunnelManager {
    private let logger = Logger(subsystem: "ai.openclaw.ios", category: "TunnelManager")

    private(set) var tunnelStatus: NEVPNStatus = .invalid
    private(set) var isConfigured: Bool = false
    private(set) var clientPublicKey: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    init() {
        Task {
            await self.loadFromSystem()
        }
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Configuration

    func configure(serverEndpoint: String, serverPublicKey: String) async throws {
        logger.info("Configuring WireGuard tunnel")

        // Generate client keypair
        let privateKey = Curve25519.generatePrivateKey()
        let publicKey = privateKey.publicKey

        // Store keys in Keychain
        try savePrivateKey(privateKey.base64Key)
        try saveServerPublicKey(serverPublicKey)

        self.clientPublicKey = publicKey.base64Key

        // Build WireGuard config
        let config = buildWireGuardConfig(
            clientPrivateKey: privateKey.base64Key,
            serverPublicKey: serverPublicKey,
            serverEndpoint: serverEndpoint
        )

        // Save to NETunnelProviderManager
        try await saveConfiguration(config: config)

        self.isConfigured = true
        logger.info("WireGuard configuration saved")
    }

    func loadFromSystem() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let existing = managers.first(where: { manager in
                (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == "ai.openclaw.ios.tunnel"
            }) {
                self.manager = existing
                self.tunnelStatus = existing.connection.status
                self.isConfigured = true

                // Load public key from Keychain
                if let privateKey = try? loadPrivateKey() {
                    let key = Curve25519.PrivateKey(base64Key: privateKey)
                    self.clientPublicKey = key?.publicKey.base64Key
                }

                setupStatusObserver()
                logger.info("Loaded existing tunnel configuration")
            } else {
                self.isConfigured = false
                logger.info("No existing tunnel configuration found")
            }
        } catch {
            logger.error("Failed to load tunnel configuration: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Connection Control

    func connect() async throws {
        guard let manager else {
            throw TunnelManagerError.notConfigured
        }

        guard manager.connection.status != .connected else {
            logger.info("Already connected")
            return
        }

        do {
            try manager.connection.startVPNTunnel()
            logger.info("Starting VPN tunnel")
        } catch {
            logger.error("Failed to start tunnel: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func disconnect() {
        guard let manager else { return }
        manager.connection.stopVPNTunnel()
        logger.info("Stopping VPN tunnel")
    }

    // MARK: - Private Helpers

    private func saveConfiguration(config: String) async throws {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "ai.openclaw.ios.tunnel"
        proto.serverAddress = "OpenClaw Gateway"
        proto.providerConfiguration = ["wgConfig": config as NSString]

        let newManager = NETunnelProviderManager()
        newManager.protocolConfiguration = proto
        newManager.localizedDescription = "OpenClaw VPN"
        newManager.isEnabled = true

        try await newManager.saveToPreferences()
        try await newManager.loadFromPreferences()

        self.manager = newManager
        self.tunnelStatus = newManager.connection.status

        setupStatusObserver()
    }

    private func setupStatusObserver() {
        guard let manager else { return }

        // Remove existing observer
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.tunnelStatus = manager.connection.status
                self.logger.info("Tunnel status changed: \(manager.connection.status.description, privacy: .public)")
            }
        }
    }

    private func buildWireGuardConfig(
        clientPrivateKey: String,
        serverPublicKey: String,
        serverEndpoint: String
    ) -> String {
        """
        [Interface]
        PrivateKey = \(clientPrivateKey)
        Address = 10.100.0.2/32
        DNS = 1.1.1.1

        [Peer]
        PublicKey = \(serverPublicKey)
        Endpoint = \(serverEndpoint)
        AllowedIPs = 0.0.0.0/0, ::/0
        PersistentKeepalive = 25
        """
    }

    // MARK: - Keychain

    private func savePrivateKey(_ key: String) throws {
        try saveToKeychain(key: "openclaw.wireguard.privateKey", value: key)
    }

    private func loadPrivateKey() throws -> String {
        try loadFromKeychain(key: "openclaw.wireguard.privateKey")
    }

    private func saveServerPublicKey(_ key: String) throws {
        try saveToKeychain(key: "openclaw.wireguard.serverPublicKey", value: key)
    }

    private func saveToKeychain(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw TunnelManagerError.invalidKey
        }

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "ai.openclaw.ios.tunnel",
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "ai.openclaw.ios.tunnel",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TunnelManagerError.keychainError(status)
        }
    }

    private func loadFromKeychain(key: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "ai.openclaw.ios.tunnel",
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else {
            throw TunnelManagerError.keychainError(status)
        }

        return string
    }
}

// MARK: - Supporting Types

enum TunnelManagerError: LocalizedError {
    case notConfigured
    case invalidKey
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Tunnel not configured"
        case .invalidKey:
            "Invalid WireGuard key"
        case .keychainError(let status):
            "Keychain error: \(status)"
        }
    }
}

extension NEVPNStatus {
    var description: String {
        switch self {
        case .invalid:
            "invalid"
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .connected:
            "connected"
        case .reasserting:
            "reasserting"
        case .disconnecting:
            "disconnecting"
        @unknown default:
            "unknown"
        }
    }
}

// MARK: - Curve25519 Helper

struct Curve25519 {
    struct PrivateKey {
        let base64Key: String

        init?(base64Key: String) {
            guard base64Key.count == 44 else { return nil }
            self.base64Key = base64Key
        }

        var publicKey: PublicKey {
            // In real implementation, this would derive the public key from the private key
            // For now, we assume WireGuardKit handles this
            PublicKey(base64Key: base64Key)
        }
    }

    struct PublicKey {
        let base64Key: String
    }

    static func generatePrivateKey() -> PrivateKey {
        var keyData = Data(count: 32)
        _ = keyData.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }

        // Clamp the key (WireGuard requirement)
        keyData[0] &= 248
        keyData[31] &= 127
        keyData[31] |= 64

        let base64 = keyData.base64EncodedString()
        return PrivateKey(base64Key: base64)!
    }
}
