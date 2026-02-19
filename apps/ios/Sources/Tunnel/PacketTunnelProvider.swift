import NetworkExtension
import WireGuardKit
import os

@MainActor
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "ai.openclaw.ios.tunnel", category: "PacketTunnel")

    private lazy var adapter: WireGuardAdapter = {
        WireGuardAdapter(with: self) { [weak self] logLevel, message in
            self?.logger.log(level: logLevel.osLogLevel, "\(message, privacy: .public)")
        }
    }()

    nonisolated override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task { @MainActor in
            await self.handleStartTunnel(options: options, completionHandler: completionHandler)
        }
    }

    private func handleStartTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) async {
        logger.info("Starting WireGuard tunnel")

        guard let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
              let configData = tunnelProtocol.providerConfiguration?["wgConfig"] as? String
        else {
            logger.error("Failed to read WireGuard config from provider configuration")
            completionHandler(TunnelError.missingConfiguration)
            return
        }

        do {
            let tunnelConfig = try TunnelConfiguration(fromWgQuickConfig: configData, called: "openclaw")
            adapter.start(tunnelConfiguration: tunnelConfig) { error in
                if let error {
                    self.logger.error("Failed to start adapter: \(error.localizedDescription, privacy: .public)")
                    completionHandler(error)
                } else {
                    self.logger.info("WireGuard tunnel started successfully")
                    completionHandler(nil)
                }
            }
        } catch {
            logger.error("Failed to parse WireGuard config: \(error.localizedDescription, privacy: .public)")
            completionHandler(error)
        }
    }

    nonisolated override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            await self.handleStopTunnel(with: reason, completionHandler: completionHandler)
        }
    }

    private func handleStopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) async {
        logger.info("Stopping WireGuard tunnel: \(reason.description, privacy: .public)")
        adapter.stop { _ in
            completionHandler()
        }
    }
}

// MARK: - Supporting Types

enum TunnelError: LocalizedError {
    case missingConfiguration

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            "WireGuard configuration not found"
        }
    }
}

extension WireGuardLogLevel {
    var osLogLevel: OSLogType {
        switch self {
        case .verbose:
            .debug
        case .error:
            .error
        @unknown default:
            .default
        }
    }
}

extension NEProviderStopReason {
    var description: String {
        switch self {
        case .none:
            "none"
        case .userInitiated:
            "user initiated"
        case .providerFailed:
            "provider failed"
        case .noNetworkAvailable:
            "no network available"
        case .unrecoverableNetworkChange:
            "unrecoverable network change"
        case .providerDisabled:
            "provider disabled"
        case .authenticationCanceled:
            "authentication canceled"
        case .configurationFailed:
            "configuration failed"
        case .idleTimeout:
            "idle timeout"
        case .configurationDisabled:
            "configuration disabled"
        case .configurationRemoved:
            "configuration removed"
        case .superceded:
            "superceded"
        case .userLogout:
            "user logout"
        case .userSwitch:
            "user switch"
        case .connectionFailed:
            "connection failed"
        case .sleep:
            "sleep"
        case .appUpdate:
            "app update"
        @unknown default:
            "unknown"
        }
    }
}
