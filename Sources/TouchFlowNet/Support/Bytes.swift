import Foundation
import TouchFlowCore

// MARK: - Hex / Base64 helpers

public enum HexCoding {
    public static func encode(_ data: Data) -> String {
        var out = String()
        out.reserveCapacity(data.count * 2)
        for b in data { out += String(format: "%02x", b) }
        return out
    }

    public static func decode(_ string: String) -> Data? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let byte = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }
}

// MARK: - Address helpers

public enum NetAddress {
    /// Returns true for IPv4 dotted-quad or IPv6 literals (no DNS lookup performed).
    public static func isIPLiteral(_ host: String) -> Bool {
        if host.isEmpty { return false }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return true }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 { return true }
        return false
    }

    public static func isIPv4(_ host: String) -> Bool {
        var v4 = in_addr()
        return inet_pton(AF_INET, host, &v4) == 1
    }

    public static func isIPv6(_ host: String) -> Bool {
        var v6 = in6_addr()
        return inet_pton(AF_INET6, host, &v6) == 1
    }

    public static func ipv4Bytes(_ host: String) -> Data? {
        var v4 = in_addr()
        guard inet_pton(AF_INET, host, &v4) == 1 else { return nil }
        return withUnsafeBytes(of: &v4) { Data($0) }
    }

    public static func ipv6Bytes(_ host: String) -> Data? {
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return nil }
        return withUnsafeBytes(of: &v6) { Data($0) }
    }

    public static func string(fromIPv4 data: Data) -> String? {
        guard data.count == 4 else { return nil }
        var addr = in_addr()
        _ = withUnsafeMutableBytes(of: &addr) { data.copyBytes(to: $0) }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buf)
    }

    public static func string(fromIPv6 data: Data) -> String? {
        guard data.count == 16 else { return nil }
        var addr = in6_addr()
        _ = withUnsafeMutableBytes(of: &addr) { data.copyBytes(to: $0) }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buf)
    }

    /// Splits "host:port" (IPv6 literals in brackets are accepted).
    public static func splitHostPort(_ s: String) -> (host: String, port: UInt16)? {
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
            guard let port = UInt16(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let idx = s.lastIndex(of: ":") else { return nil }
        let host = String(s[s.startIndex..<idx])
        guard !host.isEmpty else { return nil }
        guard let port = UInt16(s[s.index(after: idx)...]) else { return nil }
        return (host, port)
    }

    /// Parses `host:port`, `[v6]:port` or a bare host (default port).
    public static func parseAuthority(_ text: String, defaultPort: UInt16) -> (host: String, port: UInt16)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[") || trimmed.filter({ $0 == ":" }).count == 1 {
            if let parsed = splitHostPort(trimmed), !parsed.host.isEmpty {
                return parsed
            }
        }
        return (trimmed, defaultPort)
    }
}

// MARK: - CIDR

public struct IPv4CIDR: Sendable, Hashable {
    public let network: UInt32
    public let prefix: Int

    public init?(_ text: String) {
        let parts = text.split(separator: "/")
        guard parts.count == 2, let p = Int(parts[1]), p >= 0, p <= 32 else { return nil }
        guard let bytes = NetAddress.ipv4Bytes(String(parts[0])) else { return nil }
        var value: UInt32 = 0
        for b in bytes { value = (value << 8) | UInt32(b) }
        let mask: UInt32 = p == 0 ? 0 : ~UInt32(0) << (32 - UInt32(p))
        self.network = value & mask
        self.prefix = p
    }

    public func contains(ipv4: String) -> Bool {
        guard let bytes = NetAddress.ipv4Bytes(ipv4) else { return false }
        var value: UInt32 = 0
        for b in bytes { value = (value << 8) | UInt32(b) }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - UInt32(prefix))
        return (value & mask) == network
    }

    public var firstAddress: UInt32 { network }
    public var addressCount: UInt32 { prefix >= 32 ? 1 : (UInt32(1) << (32 - UInt32(prefix))) }

    /// Non-failable initializer for callers that already hold a network value.
    public init(network: UInt32, prefix: Int) {
        let clamped = min(max(prefix, 0), 32)
        let mask: UInt32 = clamped == 0 ? 0 : ~UInt32(0) << (32 - UInt32(clamped))
        self.network = network & mask
        self.prefix = clamped
    }
}

// MARK: - Host glob matching (mitmHosts)

public enum HostGlob {
    /// Supports `*` (any run of characters) and `?`, case-insensitive.
    public static func matches(_ host: String, pattern: String) -> Bool {
        let h = Array(host.lowercased().unicodeScalars.map { $0.value })
        let p = Array(pattern.lowercased().unicodeScalars.map { $0.value })
        if p.isEmpty { return false }
        if p.count == 1 && p[0] == 0x2A { return true }
        var hi = 0, pi = 0
        var starIdx = -1, match = 0
        while hi < h.count {
            if pi < p.count && (p[pi] == h[hi] || p[pi] == 0x3F) {
                hi += 1; pi += 1
            } else if pi < p.count && p[pi] == 0x2A {
                starIdx = pi
                match = hi
                pi += 1
            } else if starIdx != -1 {
                pi = starIdx + 1
                match += 1
                hi = match
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == 0x2A { pi += 1 }
        return pi == p.count
    }

    public static func matchesAny(_ host: String, patterns: [String]) -> Bool {
        for p in patterns where matches(host, pattern: p) { return true }
        return false
    }
}

// MARK: - Buffered stream

/// ByteStream wrapper with pushback plus length-delimited / line oriented reads.
public final class BufferedStream: @unchecked Sendable {
    public let stream: ByteStream
    private let lock = NSLock()
    private var buffer = Data()
    public static let defaultReadChunk = 16384

    public init(_ stream: ByteStream) { self.stream = stream }

    public var underlying: ByteStream { stream }
    public var bufferedByteCount: Int { lock.withLock { buffer.count } }

    public func pushBack(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); buffer = data + buffer; lock.unlock()
    }

    /// Returns currently buffered bytes, emptying the pushback buffer.
    public func drainBuffer() -> Data {
        lock.lock(); defer { lock.unlock() }
        let d = buffer
        buffer.removeAll()
        return d
    }

    /// Reads one byte, or nil on EOF.
    public func readByte() async throws -> UInt8? {
        if let b = lock.withLock({ takeByteLocked() }) { return b }
        guard let chunk = try await stream.read(maxLength: Self.defaultReadChunk) else { return nil }
        pushBack(chunk)
        return lock.withLock { takeByteLocked() }
    }

    private func takeByteLocked() -> UInt8? {
        guard !buffer.isEmpty else { return nil }
        let b = buffer[buffer.startIndex]
        buffer.removeFirst()
        return b
    }

    private func takeLocked(_ count: Int) -> Data? {
        guard count >= 0, buffer.count >= count else { return nil }
        let d = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(d)
    }

    private func drainLocked() -> Data? {
        let d = buffer
        buffer.removeAll()
        return d.isEmpty ? nil : d
    }

    private enum Probe {
        case value(Data)
        case tooLong(Int)
        case needMore
    }

    private func probeLineLocked(limit: Int) -> Probe {
        if let idx = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<idx]
            buffer.removeFirst(buffer.distance(from: buffer.startIndex, to: idx) + 1)
            var d = Data(line)
            if d.last == 0x0D { d.removeLast() }
            return .value(d)
        }
        if buffer.count > limit { return .tooLong(buffer.count) }
        return .needMore
    }

    private func probeUntilLocked(_ terminator: Data, limit: Int) -> Probe {
        if let range = buffer.range(of: terminator) {
            let end = buffer.distance(from: buffer.startIndex, to: range.upperBound)
            let d = buffer.prefix(end)
            buffer.removeFirst(end)
            return .value(Data(d))
        }
        if buffer.count > limit { return .tooLong(buffer.count) }
        return .needMore
    }

    /// Reads up to `maxLength` bytes, draining any pushed-back data first.
    /// Returns nil on EOF.
    public func readSome(maxLength: Int = 16 * 1024) async throws -> Data? {
        let limit = max(1, maxLength)
        if let d = lock.withLock({ () -> Data? in
            guard !buffer.isEmpty else { return nil }
            return takeLocked(min(limit, buffer.count))
        }) {
            return d
        }
        return try await stream.read(maxLength: limit)
    }

    /// Reads exactly `count` bytes or throws on EOF.
    public func readExactly(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        while true {
            if let d = lock.withLock({ takeLocked(count) }) { return d }
            guard let chunk = try await stream.read(maxLength: max(count, Self.defaultReadChunk)) else {
                throw TouchFlowError.protocolError("unexpected EOF while reading \(count) bytes")
            }
            pushBack(chunk)
        }
    }

    /// Reads until LF; strips trailing CR/LF. Nil on EOF with no data.
    public func readLine(limit: Int = 16384) async throws -> Data? {
        while true {
            switch lock.withLock({ probeLineLocked(limit: limit) }) {
            case .value(let d):
                return d
            case .tooLong(let size):
                throw TouchFlowError.protocolError("line exceeds \(limit) bytes (buffered \(size))")
            case .needMore:
                guard let chunk = try await stream.read(maxLength: Self.defaultReadChunk) else {
                    return lock.withLock { drainLocked() }
                }
                pushBack(chunk)
            }
        }
    }

    /// Reads until `terminator` (inclusive) is found in the buffered data.
    public func readUntil(_ terminator: Data, limit: Int = 65536) async throws -> Data? {
        while true {
            switch lock.withLock({ probeUntilLocked(terminator, limit: limit) }) {
            case .value(let d):
                return d
            case .tooLong(let size):
                throw TouchFlowError.protocolError("header exceeds \(limit) bytes (buffered \(size))")
            case .needMore:
                guard let chunk = try await stream.read(maxLength: Self.defaultReadChunk) else {
                    return lock.withLock { drainLocked() }
                }
                pushBack(chunk)
            }
        }
    }

    public func write(_ data: Data) async throws { try await stream.write(data) }

    public func close() { stream.close() }
}

// MARK: - Small utilities

enum DataUtil {
    static func u16(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    static func readU16(_ data: Data, at index: Int) -> UInt16? {
        guard index + 1 < data.count else { return nil }
        let base = data.startIndex + index
        return (UInt16(data[base]) << 8) | UInt16(data[base + 1])
    }

    static func concat(_ parts: [Data]) -> Data {
        var out = Data()
        out.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for p in parts { out.append(p) }
        return out
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return SecRandomCopyBytes(kSecRandomDefault, count, base) == errSecSuccess
        }
        if !ok {
            var rng = SystemRandomNumberGenerator()
            return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
        }
        return data
    }
}
