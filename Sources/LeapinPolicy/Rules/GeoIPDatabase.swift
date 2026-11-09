import Foundation

/// A deliberately small, offline GeoIP seed table: a coarse China prefix list plus
/// well-known reserved/US ranges. It is *not* a substitute for a full GeoIP database —
/// unknown addresses return `nil` and never throw.
public final class GeoIPDatabase: @unchecked Sendable {
    public static let shared = GeoIPDatabase()

    private struct Entry: Sendable {
        let start: UInt32
        let end: UInt32
        let country: String
    }

    private let v4Entries: [Entry]
    private let v6Reserved: [(CIDR, String)]

    /// Coarse China prefixes (CN). Mix of specific allocations and /8 aggregates that are
    /// predominantly Chinese; documented as approximate in docs/policy.md.
    private static let chinaPrefixes: [String] = [
        "1.0.1.0/24", "1.0.2.0/23", "1.0.8.0/21", "1.0.32.0/19", "1.1.0.0/24",
        "1.1.2.0/23", "1.1.4.0/22", "1.1.8.0/24", "1.1.16.0/20", "1.1.32.0/19",
        "1.2.0.0/23", "1.2.2.0/24", "1.2.4.0/22", "1.2.8.0/24", "1.2.16.0/20",
        "1.2.32.0/19", "1.2.64.0/18", "1.3.0.0/16", "14.0.0.0/8", "27.0.0.0/8",
        "36.0.0.0/8", "39.0.0.0/8", "42.0.0.0/8", "49.0.0.0/8", "58.0.0.0/7",
        "59.0.0.0/8", "60.0.0.0/7", "61.0.0.0/8", "101.0.0.0/8", "103.0.0.0/8",
        "106.0.0.0/8", "110.0.0.0/7", "111.0.0.0/8", "112.0.0.0/5", "113.0.0.0/8",
        "114.0.0.0/8", "115.0.0.0/8", "116.0.0.0/8", "120.0.0.0/6", "124.0.0.0/7",
        "125.0.0.0/8", "171.0.0.0/8", "175.0.0.0/8", "180.0.0.0/8", "182.0.0.0/8",
        "183.0.0.0/8", "202.96.0.0/12", "203.208.32.0/19", "211.0.0.0/8", "218.0.0.0/8",
        "219.0.0.0/8", "220.0.0.0/8", "221.0.0.0/8", "222.0.0.0/8", "223.0.0.0/8",
    ]

    private static let usPrefixes: [String] = [
        "1.1.1.0/24", "1.0.0.0/24", "8.8.8.0/24", "8.8.4.0/24", "13.32.0.0/15",
        "23.0.0.0/12", "104.16.0.0/13", "142.250.0.0/15", "151.101.0.0/16", "199.232.0.0/16",
    ]

    private static let reservedPrefixes: [String] = [
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
        "172.16.0.0/12", "192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24",
        "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4",
    ]

    public init() {
        var entries: [Entry] = []
        func add(_ prefixes: [String], _ country: String) {
            for text in prefixes {
                guard let cidr = CIDR(text), cidr.isIPv4 else { continue }
                let start = GeoIPDatabase.uint32(cidr.networkBytes)
                let end = GeoIPDatabase.uint32(cidr.upperBoundBytes)
                entries.append(Entry(start: start, end: end, country: country))
            }
        }
        add(GeoIPDatabase.chinaPrefixes, "CN")
        add(GeoIPDatabase.usPrefixes, "US")
        add(GeoIPDatabase.reservedPrefixes, "PRIVATE")
        entries.sort { $0.start < $1.start }
        self.v4Entries = entries

        var v6: [(CIDR, String)] = []
        for text in ["::1/128", "fe80::/10", "fc00::/7", "::/128"] {
            if let cidr = CIDR(text) { v6.append((cidr, "PRIVATE")) }
        }
        self.v6Reserved = v6
    }

    /// Returns "CN", "US", "PRIVATE" for reserved ranges, or nil when unknown.
    public func country(of ip: String) -> String? {
        let address = HostNormalizer.normalize(ip)
        guard !address.isEmpty else { return nil }
        if let v4 = IPParse.ipv4(address) {
            var low = 0
            var high = v4Entries.count - 1
            var found: Entry?
            while low <= high {
                let mid = (low + high) / 2
                let entry = v4Entries[mid]
                if v4 < entry.start {
                    high = mid - 1
                } else if v4 > entry.end {
                    low = mid + 1
                } else {
                    found = entry
                    break
                }
            }
            return found?.country
        }
        if let v6 = IPParse.ipv6(address) {
            for (cidr, country) in v6Reserved where cidr.contains(ipv6: v6) {
                return country
            }
        }
        return nil
    }

    public func contains(_ ip: String, country: String) -> Bool {
        guard let actual = self.country(of: ip) else { return false }
        return actual.caseInsensitiveCompare(country) == .orderedSame
    }

    private static func uint32(_ bytes: [UInt8]) -> UInt32 {
        guard bytes.count == 4 else { return 0 }
        return UInt32(bytes[0]) * 16_777_216 + UInt32(bytes[1]) * 65_536
            + UInt32(bytes[2]) * 256 + UInt32(bytes[3])
    }
}
