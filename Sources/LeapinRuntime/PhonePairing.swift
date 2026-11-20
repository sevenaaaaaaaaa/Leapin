import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Everything the phone needs to reach this Mac, plus the reasons it currently
/// cannot — the UI shows the blockers instead of a bare address.
public struct PhonePairing: Sendable {
    public var host: String
    public var port: Int
    public var token: String
    public var lanEnabled: Bool
    public var controlRunning: Bool
    /// Empty when a phone on the same Wi-Fi can connect right now.
    public var blockers: [String]

    public init(host: String, port: Int, token: String, lanEnabled: Bool,
                controlRunning: Bool, blockers: [String]) {
        self.host = host
        self.port = port
        self.token = token
        self.lanEnabled = lanEnabled
        self.controlRunning = controlRunning
        self.blockers = blockers
    }

    /// What the Mac renders as a QR and the phone parses back.
    public var pairingURL: String {
        var components = URLComponents()
        components.scheme = "leapin"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: "\(port)"),
            URLQueryItem(name: "token", value: token),
        ]
        return components.string ?? ""
    }

    /// First private IPv4 address on an active interface.
    ///
    /// The control plane binds loopback unless LAN access is on, so this is the
    /// address the phone has to dial; a wrong one makes pairing fail with a
    /// timeout the user cannot interpret.
    public static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [(name: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let addr = interface.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            guard name != "lo0" else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(addr.pointee.sa_len)
            guard getnameinfo(addr, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: buffer)
            guard isPrivateIPv4(text) else { continue }
            candidates.append((name, text))
        }
        // en0 is Wi-Fi on a laptop; prefer it over hotspot or virtual interfaces.
        if let wifi = candidates.first(where: { $0.name == "en0" }) { return wifi.address }
        return candidates.first?.address
    }

    static func isPrivateIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        default: return false
        }
    }
}
