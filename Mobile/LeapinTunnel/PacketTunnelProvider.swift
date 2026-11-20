import Foundation
import NetworkExtension
import os.log

/// The packet tunnel that will carry the phone's traffic into the same engine the
/// app already runs.
///
/// Milestone M2: this starts, configures the virtual interface, reports status, and
/// counts packets. Turning those packets into proxy connections needs a userspace
/// TCP/IP stack (tun2socks), which is the next step — it is not faked here.
/// Loading any NetworkExtension requires a paid team id with the
/// network-extension entitlement; a free Apple ID cannot sign this bundle.
final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = OSLog(subsystem: "app.leapin.mobile.tunnel", category: "tunnel")
    private var counters = (read: 0, written: 0)
    private let queue = DispatchQueue(label: "app.leapin.tunnel.io")

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
        settings.mtu = 1500

        let ipv4 = NEIPv4Settings(addresses: ["10.7.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: ["10.7.0.1"])

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                os_log("tunnel settings failed: %{public}@", log: self.log, type: .error, String(describing: error))
                completionHandler(error)
                return
            }
            self.readPackets()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        os_log("tunnel stopping: %{public}d", log: log, type: .info, reason.rawValue)
        completionHandler()
    }

    /// Reads packets so the interface is live and the counters prove traffic arrives.
    /// They are dropped for now: forwarding needs the stack described above.
    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.counters.read += packets.count
            if self.counters.read % 50 == 0 {
                os_log("tunnel read %{public}d packets", log: self.log, type: .debug, self.counters.read)
            }
            self.readPackets()
        }
    }
}
