import Foundation
import LeapinCore

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
    /// A flat byte store with a read cursor: consuming data only advances head, so
    /// draining a 32 MB body never re-copies what is left behind it. The previous
    /// Data.removeFirst version moved the whole remainder on every read, which made
    /// transfer time quadratic in the body size.
    private var storage: [UInt8] = []
    private var head = 0
    public static let defaultReadChunk = 16384
    /// Compact once the consumed prefix is this large and at least half the array.
    private static let compactThreshold = 8192

    public init(_ stream: ByteStream) { self.stream = stream }

    public var underlying: ByteStream { stream }
    public var bufferedByteCount: Int { lock.withLock { availableLocked } }

    public func pushBack(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { prependLocked(data) }
    }

    /// Returns currently buffered bytes, emptying the pushback buffer.
    public func drainBuffer() -> Data {
        lock.withLock { drainLocked() ?? Data() }
    }

    /// Reads one byte, or nil on EOF.
    public func readByte() async throws -> UInt8? {
        if let byte = lock.withLock({ takeByteLocked() }) { return byte }
        guard let chunk = try await stream.read(maxLength: Self.defaultReadChunk) else { return nil }
        lock.withLock { appendLocked(chunk) }
        return lock.withLock { takeByteLocked() }
    }

    /// Reads up to maxLength bytes, draining any pushed-back data first.
    /// Returns nil on EOF.
    public func readSome(maxLength: Int = 16 * 1024) async throws -> Data? {
        let limit = max(1, maxLength)
        if let data = lock.withLock({ () -> Data? in
            guard availableLocked > 0 else { return nil }
            return takeLocked(min(limit, availableLocked))
        }) {
            return data
        }
        return try await stream.read(maxLength: limit)
    }

    /// Reads exactly count bytes or throws on EOF.
    public func readExactly(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        while true {
            if let data = lock.withLock({ takeLocked(count) }) { return data }
            guard let chunk = try await stream.read(maxLength: max(count, Self.defaultReadChunk)) else {
                throw LeapinError.protocolError("unexpected EOF while reading \(count) bytes")
            }
            lock.withLock { appendLocked(chunk) }
        }
    }

    /// Reads until LF; strips trailing CR/LF. Nil on EOF with no data.
    public func readLine(limit: Int = 16384) async throws -> Data? {
        while true {
            switch lock.withLock({ probeLineLocked(limit: limit) }) {
            case .value(let data):
                return data
            case .tooLong(let size):
                throw LeapinError.protocolError("line exceeds \(limit) bytes (buffered \(size))")
            case .needMore:
                guard let chunk = try await stream.read(maxLength: Self.defaultReadChunk) else {
                    return lock.withLock { drainLocked() }
                }
                lock.withLock { appendLocked(chunk) }
            }
        }
    }

    /// Reads until terminator (inclusive) is found in the buffered data.
    public func readUntil(_ terminator: Data, limit: Int = 65536) async throws -> Data? {
        while true {
            switch lock.withLock({ probeUntilLocked(terminator, limit: limit) }) {
            case .value(let data):
                return data
            case .tooLong(let size):
                throw LeapinError.protocolError("header exceeds \(limit) bytes (buffered \(size))")
            case .needMore:
                guard let chunk = try await stream.read(maxLength: Self.defaultReadChunk) else {
                    return lock.withLock { drainLocked() }
                }
                lock.withLock { appendLocked(chunk) }
            }
        }
    }

    public func write(_ data: Data) async throws { try await stream.write(data) }

    public func close() { stream.close() }

    // MARK: - Buffer internals (lock held)

    private enum Probe {
        case value(Data)
        case tooLong(Int)
        case needMore
    }

    private var availableLocked: Int { storage.count - head }

    private func compactLocked() {
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= Self.compactThreshold && head * 2 >= storage.count {
            // One move for many small reads; amortised to O(1) per byte.
            storage.removeFirst(head)
            head = 0
        }
    }

    private func consumeLocked(_ count: Int) -> Data {
        let slice = storage[head..<(head + count)]
        head += count
        compactLocked()
        return Data(slice)
    }

    private func appendLocked(_ data: Data) {
        compactLocked()
        storage.append(contentsOf: data)
    }

    private func prependLocked(_ data: Data) {
        let bytes = [UInt8](data)
        if bytes.count <= head {
            let start = head - bytes.count
            storage.replaceSubrange(start..<head, with: bytes)
            head = start
        } else {
            storage = bytes + storage[head...]
            head = 0
        }
    }

    private func takeByteLocked() -> UInt8? {
        guard availableLocked > 0 else { return nil }
        let byte = storage[head]
        head += 1
        compactLocked()
        return byte
    }

    private func takeLocked(_ count: Int) -> Data? {
        guard count >= 0, availableLocked >= count else { return nil }
        return consumeLocked(count)
    }

    private func drainLocked() -> Data? {
        guard availableLocked > 0 else {
            storage.removeAll(keepingCapacity: true)
            head = 0
            return nil
        }
        let out = Data(storage[head...])
        storage.removeAll(keepingCapacity: true)
        head = 0
        return out
    }

    private func probeLineLocked(limit: Int) -> Probe {
        if let index = storage[head...].firstIndex(of: 0x0A) {
            let count = index - head + 1
            var data = consumeLocked(count)
            // consumeLocked includes the LF; strip it, then the CR before it.
            if data.last == 0x0A { data.removeLast() }
            if data.last == 0x0D { data.removeLast() }
            return .value(data)
        }
        if availableLocked > limit { return .tooLong(availableLocked) }
        return .needMore
    }

    private func probeUntilLocked(_ terminator: Data, limit: Int) -> Probe {
        if let start = firstIndexLocked(of: [UInt8](terminator)) {
            let count = start - head + terminator.count
            return .value(consumeLocked(count))
        }
        if availableLocked > limit { return .tooLong(availableLocked) }
        return .needMore
    }

    /// First occurrence of needle at or after the cursor. Terminators are a few
    /// bytes, so the naive scan costs nothing next to the copy it replaces.
    private func firstIndexLocked(of needle: [UInt8]) -> Int? {
        guard !needle.isEmpty, availableLocked >= needle.count else { return nil }
        let last = storage.count - needle.count
        var index = head
        while index <= last {
            if storage[index] == needle[0] {
                var matched = true
                for offset in 1..<needle.count where storage[index + offset] != needle[offset] {
                    matched = false
                    break
                }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }
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