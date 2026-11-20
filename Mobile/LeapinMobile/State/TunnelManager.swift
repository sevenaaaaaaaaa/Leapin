import Foundation
import NetworkExtension

/// Installs and drives the packet tunnel.
///
/// Loading a NetworkExtension requires a paid team id with the
/// network-extension entitlement. Without it saveToPreferences fails and the
/// error is surfaced as-is instead of pretending the tunnel works.
@MainActor
@Observable
final class TunnelManager {
    static let shared = TunnelManager()

    private(set) var status: NEVPNStatus = .invalid
    private(set) var isInstalled = false
    private(set) var lastError: String?
    private(set) var isBusy = false

    private var manager: NETunnelProviderManager?

    var statusText: String {
        switch status {
        case .connected: return "已接管"
        case .connecting: return "接管中…"
        case .disconnecting: return "断开中…"
        case .reasserting: return "重连中…"
        case .disconnected: return "已断开"
        case .invalid: return isInstalled ? "已安装" : "未安装"
        @unknown default: return "未知"
        }
    }

    func refresh() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let ours = managers.first { item in
                (item.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == "app.leapin.mobile.tunnel"
            }
            manager = ours
            isInstalled = ours != nil
            status = ours?.connection.status ?? .invalid
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func install() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = "app.leapin.mobile.tunnel"
            configuration.serverAddress = "Leapin 本机引擎"

            let fresh = NETunnelProviderManager()
            fresh.protocolConfiguration = configuration
            fresh.localizedDescription = "Leapin"
            fresh.isEnabled = true
            try await fresh.saveToPreferences()
            try await fresh.loadFromPreferences()
            manager = fresh
            isInstalled = true
            lastError = nil
            await refresh()
        } catch {
            // The usual failure here is a missing network-extension entitlement on a
            // free signing identity; the message says so and we do not hide it.
            lastError = error.localizedDescription
        }
    }

    func start() async {
        if manager == nil { await install() }
        guard let manager else { return }
        do {
            try manager.connection.startVPNTunnel()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
        status = .disconnected
    }
}
