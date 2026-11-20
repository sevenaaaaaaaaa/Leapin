import Foundation
import NetworkExtension
import os.log
import LeapinCore
import LeapinNet

/// The packet tunnel: TUN packets are terminated by TunTCPRelay and carried into the
/// same engine the app runs, over SOCKS5 on loopback.
///
/// Loading a NetworkExtension requires a paid team id with the network-extension
/// entitlement; a free Apple ID cannot sign this bundle, and the app says so.
final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = OSLog(subsystem: "app.leapin.mobile.tunnel", category: "tunnel")
    private var relay: TunTCPRelay?
    private var udpRelay: TunUDPRelay?
    private var engine: ProxyServer?
    private var enginePort: UInt16 = 0
    private var counters = (read: 0, written: 0)

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        do {
            try startEngine()
        } catch {
            os_log("engine failed: %{public}@", log: log, type: .error, String(describing: error))
            completionHandler(error)
            return
        }

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
            let relay = TunTCPRelay(localAddress: 0x0A070001) { host, port in
                try await Socks5.connect(via: self.enginePort, host: host, port: port)
            }
            relay.emit = { [weak self] packet in
                self?.write(packet)
            }
            self.relay = relay

            let udp = TunUDPRelay()
            udp.emit = { [weak self] packet in
                self?.write(packet)
            }
            udp.start()
            self.udpRelay = udp
            self.readPackets()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        relay = nil
        udpRelay?.stop()
        udpRelay = nil
        engine?.stop()
        engine = nil
        completionHandler()
    }

    // MARK: - Engine

    private func startEngine() throws {
        let resolver = DNSResolver(config: DNSConfig(mode: .system, upstreams: [], fallback: [], cacheTTL: 120))
        let server = try ProxyServer(options: .init(port: 0, allowLAN: false),
                                     router: TunnelDirectRouter(),
                                     resolver: resolver,
                                     blocker: nil,
                                     flows: nil,
                                     capture: nil)
        try server.start()
        engine = server
        enginePort = server.listeningPort
        os_log("tunnel engine on %{public}d", log: log, type: .info, Int(enginePort))
    }

    // MARK: - Packets

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.counters.read += packets.count
            for packet in packets {
                switch packet.count > 9 ? packet[packet.startIndex + 9] : 0 {
                case 6: self.relay?.handle(packet: packet)
                case 17: self.udpRelay?.handle(packet: packet)
                default: break
                }
            }
            self.readPackets()
        }
    }

    private func write(_ packet: Data) {
        counters.written += 1
        packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
    }
}

/// Rules and outbounds live in the engine; the tunnel only needs a policy today.
private struct TunnelDirectRouter: RouteDeciding {
    func decide(_ meta: ConnectionMeta) -> RouteDecision {
        RouteDecision(policy: "DIRECT", outbound: .direct)
    }
}
