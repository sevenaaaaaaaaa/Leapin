import Foundation
import Network
import LeapinCore

/// Long-lived upstream transports (DNS-03).
///
/// The old code built an NWConnection, a DispatchQueue and a task group for every
/// single query; at a few hundred queries per second that setup cost dominated the
/// actual work. Here each endpoint keeps one transport alive, and queries to one
/// endpoint are serialized inside its actor, so a reply can never be paired with a
/// different query's datagram.
actor DNSUpstreamPool {
    private var udpConnections: [String: UDPUpstreamConnection] = [:]
    private var dotConnections: [String: DoTUpstreamConnection] = [:]

    func udp(host: String, port: UInt16) -> UDPUpstreamConnection {
        let key = "\(host):\(port)"
        if let existing = udpConnections[key] { return existing }
        let fresh = UDPUpstreamConnection(host: host, port: port)
        udpConnections[key] = fresh
        return fresh
    }

    func dot(host: String, port: UInt16) -> DoTUpstreamConnection {
        let key = "\(host):\(port)"
        if let existing = dotConnections[key] { return existing }
        let fresh = DoTUpstreamConnection(host: host, port: port)
        dotConnections[key] = fresh
        return fresh
    }

    /// Sockets really opened per transport, for the reuse tests and for logs.
    func openedConnections() async -> (udp: Int, dot: Int) {
        var udpCount = 0
        for connection in udpConnections.values { udpCount += await connection.openedConnections }
        var dotCount = 0
        for connection in dotConnections.values { dotCount += await connection.openedConnections }
        return (udpCount, dotCount)
    }

    func closeAll() async {
        for connection in udpConnections.values { await connection.close() }
        for connection in dotConnections.values { await connection.close() }
        udpConnections.removeAll()
        dotConnections.removeAll()
    }
}

// MARK: - Serialization

/// A non-reentrant async gate.
///
/// An actor method suspends at every `await`, so two queries could otherwise be
/// inside one transport's send/receive window at the same time and steal each
/// other's datagrams. The gate keeps one exchange in flight per transport.
final class SerialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        // Resuming inside the lock would let the continuation run inline and call
        // release re-entrantly, so the hand-off happens after the lock is dropped.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let entered = lock.withLock { () -> Bool in
                if !busy {
                    busy = true
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if entered { continuation.resume() }
        }
    }

    func release() {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !waiters.isEmpty else {
                busy = false
                return nil
            }
            // Ownership passes straight to the next waiter, so nobody can slip in
            // between a release and the hand-over.
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

// MARK: - UDP

/// One UDP upstream, reused until it fails.
actor UDPUpstreamConnection {
    private let host: String
    private let port: UInt16
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private let gate = SerialGate()
    private(set) var openedConnections = 0

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        self.queue = DispatchQueue(label: "com.leapin.dns.upstream.\(host)_\(port)")
    }

    func exchange(_ payload: Data, timeout: TimeInterval) async throws -> Data {
        await gate.acquire()
        defer { gate.release() }
        let connection = try await ready(timeout: timeout)
        do {
            return try await roundTrip(connection, payload: payload, timeout: timeout)
        } catch {
            // A failed exchange can leave a half-dead socket behind; the next query
            // starts from a fresh one instead of waiting for the same failure.
            close()
            throw error
        }
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    private func ready(timeout: TimeInterval) async throws -> NWConnection {
        if let connection, connection.state == .ready { return connection }
        close()

        let options = NWProtocolUDP.Options()
        let parameters = NWParameters(dtls: nil, udp: options)
        let host = self.host
        let fresh = NWConnection(host: NWEndpoint.Host(host),
                                 port: NWEndpoint.Port(rawValue: port) ?? 53,
                                 using: parameters)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceBox()
            fresh.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error):
                    if once.claim() {
                        continuation.resume(throwing: LeapinError.connectionFailed(
                            "udp \(host): \(error.localizedDescription)"))
                    }
                case .cancelled:
                    if once.claim() {
                        continuation.resume(throwing: LeapinError.connectionFailed("udp \(host): cancelled"))
                    }
                default:
                    break
                }
            }
            fresh.start(queue: queue)
            queue.asyncAfter(deadline: .now() + max(timeout, 0.2)) {
                if once.claim() {
                    fresh.cancel()
                    continuation.resume(throwing: LeapinError.timeout)
                }
            }
        }
        openedConnections += 1
        connection = fresh
        return fresh
    }

    private func roundTrip(_ connection: NWConnection, payload: Data, timeout: TimeInterval) async throws -> Data {
        let expected = Self.identifier(of: payload)
        let host = self.host
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceBox()
            connection.send(content: payload, completion: .contentProcessed { error in
                guard once.claim() else { return }
                if let error {
                    continuation.resume(throwing: LeapinError.connectionFailed(
                        "udp send \(host): \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            })
            queue.asyncAfter(deadline: .now() + max(timeout, 0.2)) {
                if once.claim() { continuation.resume(throwing: LeapinError.timeout) }
            }
        }

        let deadline = Date().addingTimeInterval(max(timeout, 0.2))
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw LeapinError.timeout }
            guard let data = try await receive(connection, timeout: remaining) else {
                throw LeapinError.connectionFailed("udp \(host): closed")
            }
            // A late answer to an exchange that already timed out carries a stale
            // id; drop it rather than hand it to this query.
            if data.count >= 2, Self.identifier(of: data) == expected { return data }
        }
    }

    private func receive(_ connection: NWConnection, timeout: TimeInterval) async throws -> Data? {
        let host = self.host
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            let once = OnceBox()
            connection.receiveMessage { data, _, _, error in
                guard once.claim() else { return }
                if let error {
                    continuation.resume(throwing: LeapinError.connectionFailed(
                        "udp receive \(host): \(error.localizedDescription)"))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: nil)
                }
            }
            queue.asyncAfter(deadline: .now() + max(timeout, 0.05)) {
                if once.claim() { continuation.resume(throwing: LeapinError.timeout) }
            }
        }
    }

    static func identifier(of payload: Data) -> UInt16? {
        guard payload.count >= 2 else { return nil }
        let bytes = [UInt8](payload.prefix(2))
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }
}

// MARK: - DNS over TLS

/// One TLS connection to a DoT upstream, reused for every query.
actor DoTUpstreamConnection {
    private let host: String
    private let port: UInt16
    private var socket: NetSocket?
    private var stream: BufferedStream?
    private var lastUsed = Date.distantPast
    private let gate = SerialGate()
    private let idleLimit: TimeInterval = 60
    private(set) var openedConnections = 0

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func exchange(_ payload: Data, timeout: TimeInterval) async throws -> Data {
        await gate.acquire()
        defer { gate.release() }
        let reused = socket != nil
        do {
            return try await attempt(payload, timeout: timeout)
        } catch {
            close()
            // An idle DoT connection may have been closed by the server while it sat
            // here; a stale socket is worth exactly one retry on a fresh one.
            guard reused else { throw error }
            return try await attempt(payload, timeout: timeout)
        }
    }

    func close() {
        socket?.close()
        socket = nil
        stream = nil
    }

    private func attempt(_ payload: Data, timeout: TimeInterval) async throws -> Data {
        let (socket, stream) = try await ready(timeout: timeout)
        do {
            var framed = Data([UInt8((payload.count >> 8) & 0xFF), UInt8(payload.count & 0xFF)])
            framed.append(payload)
            try await socket.write(framed)
            let lengthData = try await withDeadline(timeout) { try await stream.readExactly(2) }
            guard lengthData.count == 2 else {
                throw LeapinError.connectionFailed("dot \(host): short length prefix")
            }
            let bytes = [UInt8](lengthData)
            let length = Int(bytes[0]) << 8 | Int(bytes[1])
            guard length > 0 else {
                throw LeapinError.connectionFailed("dot \(host): empty response")
            }
            let body = try await withDeadline(timeout) { try await stream.readExactly(length) }
            lastUsed = Date()
            return body
        } catch {
            close()
            throw error
        }
    }

    private func ready(timeout: TimeInterval) async throws -> (NetSocket, BufferedStream) {
        if let socket, let stream, Date().timeIntervalSince(lastUsed) < idleLimit {
            return (socket, stream)
        }
        close()
        let host = self.host
        let options = TLSFactory.clientOptions(serverName: host, alpn: ["dot"])
        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: port) ?? 853,
                                      using: parameters)
        let fresh = NetSocket(connection: connection, description: "dot:\(host):\(port)")
        try await fresh.start(timeout: timeout)
        openedConnections += 1
        let buffer = BufferedStream(fresh)
        socket = fresh
        stream = buffer
        lastUsed = Date()
        return (fresh, buffer)
    }

    /// Runs one read against a wall clock. On expiry the caller closes the socket,
    /// which resumes the pending read and lets it unwind instead of leaking a task.
    private func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                                           _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 0.05) * 1_000_000_000))
                throw LeapinError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LeapinError.timeout }
            return first
        }
    }
}
