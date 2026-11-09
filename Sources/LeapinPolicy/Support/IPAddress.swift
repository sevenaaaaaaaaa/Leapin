import Foundation

// MARK: - IP parsing

/// Small, dependency-free IPv4/IPv6 helpers shared by rules, GeoIP and adblock code.
public enum IPParse {
    /// Parses a dotted-quad IPv4 address (no shorthand, no leading zeros).
    public static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let octet = UInt32(part), octet <= 255 else { return nil }
            if part.count > 1 && part.first == "0" { return nil }
            value = value * 256 + octet
        }
        return value
    }

    public static func ipv4String(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    /// Parses an IPv6 address, including `::` compression and an embedded IPv4 tail.
    public static func ipv6(_ text: String) -> [UInt8]? {
        var str = text.trimmingCharacters(in: .whitespaces)
        if let zone = str.firstIndex(of: "%") { str = String(str[..<zone]) }
        guard !str.isEmpty else { return nil }

        func parseGroups(_ body: String) -> [UInt16]? {
            if body.isEmpty { return [] }
            let tokens = body.split(separator: ":", omittingEmptySubsequences: false)
            var out: [UInt16] = []
            for (index, token) in tokens.enumerated() {
                if token.isEmpty { return nil }
                if token.contains(".") {
                    guard index == tokens.count - 1, let v4 = ipv4(String(token)) else { return nil }
                    out.append(UInt16(v4 / 65536))
                    out.append(UInt16(v4 % 65536))
                } else {
                    guard token.count <= 4, let group = UInt16(token, radix: 16) else { return nil }
                    out.append(group)
                }
            }
            return out
        }

        let halves = str.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        var groups: [UInt16] = []
        if halves.count == 2 {
            guard let head = parseGroups(halves[0]), let tail = parseGroups(halves[1]) else { return nil }
            let zeros = 8 - head.count - tail.count
            guard zeros >= 0 else { return nil }
            groups = head + Array(repeating: 0, count: zeros) + tail
        } else {
            guard let all = parseGroups(str) else { return nil }
            groups = all
        }
        guard groups.count == 8 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        for group in groups {
            bytes.append(UInt8(group / 256))
            bytes.append(UInt8(group % 256))
        }
        return bytes
    }

    public static func ipv6String(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return "" }
        var groups: [String] = []
        for i in stride(from: 0, to: 16, by: 2) {
            groups.append(String(UInt16(bytes[i]) * 256 + UInt16(bytes[i + 1]), radix: 16))
        }
        return groups.joined(separator: ":")
    }
}

// MARK: - CIDR

/// A parsed network prefix that can test IPv4/IPv6 addresses without allocations.
public struct CIDR: Sendable, Hashable, CustomStringConvertible {
    public enum Family: Sendable, Hashable { case v4, v6 }

    public let family: Family
    public let networkBytes: [UInt8]
    public let prefix: Int

    public init?(ipv4Network: UInt32, prefix: Int) {
        guard prefix >= 0, prefix <= 32 else { return nil }
        var bytes: [UInt8] = [
            UInt8((ipv4Network >> 24) & 0xFF), UInt8((ipv4Network >> 16) & 0xFF),
            UInt8((ipv4Network >> 8) & 0xFF), UInt8(ipv4Network & 0xFF),
        ]
        CIDR.mask(&bytes, prefix: prefix)
        self.family = .v4
        self.networkBytes = bytes
        self.prefix = prefix
    }

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let pieces = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, let prefix = Int(pieces[1]), prefix >= 0 else { return nil }
        let host = String(pieces[0])
        if let v4 = IPParse.ipv4(host) {
            guard prefix <= 32 else { return nil }
            var bytes: [UInt8] = [
                UInt8((v4 >> 24) & 0xFF), UInt8((v4 >> 16) & 0xFF),
                UInt8((v4 >> 8) & 0xFF), UInt8(v4 & 0xFF),
            ]
            CIDR.mask(&bytes, prefix: prefix)
            self.family = .v4
            self.networkBytes = bytes
            self.prefix = prefix
        } else if let v6 = IPParse.ipv6(host) {
            guard prefix <= 128 else { return nil }
            var bytes = v6
            CIDR.mask(&bytes, prefix: prefix)
            self.family = .v6
            self.networkBytes = bytes
            self.prefix = prefix
        } else {
            return nil
        }
    }

    public var isIPv4: Bool { family == .v4 }

    public func contains(ipv4 value: UInt32) -> Bool {
        guard family == .v4 else { return false }
        var bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ]
        CIDR.mask(&bytes, prefix: prefix)
        return bytes == networkBytes
    }

    public func contains(ipv6 value: [UInt8]) -> Bool {
        guard family == .v6, value.count == 16 else { return false }
        var bytes = value
        CIDR.mask(&bytes, prefix: prefix)
        return bytes == networkBytes
    }

    /// Convenience: matches a textual address regardless of family.
    public func contains(address: String) -> Bool {
        switch family {
        case .v4:
            guard let v4 = IPParse.ipv4(address) else { return false }
            return contains(ipv4: v4)
        case .v6:
            guard let v6 = IPParse.ipv6(address) else { return false }
            return contains(ipv6: v6)
        }
    }

    public var upperBoundBytes: [UInt8] {
        var bytes = networkBytes
        for i in bytes.indices {
            let bitStart = i * 8
            if bitStart >= prefix {
                bytes[i] = 0xFF
            } else if prefix - bitStart < 8 {
                bytes[i] |= UInt8((1 << (8 - (prefix - bitStart))) - 1)
            }
        }
        return bytes
    }

    public var description: String {
        if family == .v4 {
            let value = UInt32(networkBytes[0]) * 16_777_216 + UInt32(networkBytes[1]) * 65_536
                + UInt32(networkBytes[2]) * 256 + UInt32(networkBytes[3])
            return "\(IPParse.ipv4String(value))/\(prefix)"
        }
        return "\(IPParse.ipv6String(networkBytes))/\(prefix)"
    }

    /// Widens a plain address to its full-length prefix, e.g. "1.2.3.4" -> /32.
    public static func host(_ text: String) -> CIDR? {
        if IPParse.ipv4(text) != nil { return CIDR("\(text)/32") }
        if IPParse.ipv6(text) != nil { return CIDR("\(text)/128") }
        return nil
    }

    private static func mask(_ bytes: inout [UInt8], prefix: Int) {
        for i in bytes.indices {
            let bitStart = i * 8
            if bitStart >= prefix {
                bytes[i] = 0
            } else if prefix - bitStart < 8 {
                bytes[i] &= UInt8(truncatingIfNeeded: 0xFF << (8 - (prefix - bitStart)))
            }
        }
    }
}

// MARK: - Host normalization

public enum HostNormalizer {
    /// Lowercases a host, strips a port suffix, IPv6 brackets and the root trailing dot.
    public static func normalize(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return host }
        if host.hasPrefix("[") {
            if let close = host.firstIndex(of: "]") {
                host = String(host[host.index(after: host.startIndex)..<close])
            }
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            if !port.isEmpty, port.allSatisfy({ $0.isNumber }), IPParse.ipv4(String(host[..<colon])) != nil {
                host = String(host[..<colon])
            }
        }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// True when `host` equals `domain` or is a subdomain of it (label boundary aware).
    public static func matchesSuffix(_ host: String, _ domain: String) -> Bool {
        if host == domain { return true }
        guard host.hasSuffix(domain) else { return false }
        return host.hasSuffix("." + domain)
    }
}
