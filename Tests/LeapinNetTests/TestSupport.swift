import Foundation
import Network
import XCTest
@testable import LeapinCore
@testable import LeapinNet

// MARK: - Policy doubles

/// Router double: per-host outbound, plus a default.
final class StaticRouter: RouteDeciding, @unchecked Sendable {
    private let lock = NSLock()
    private var byHost: [String: OutboundConfig] = [:]
    private let fallback: OutboundConfig
    private var seenMetas: [ConnectionMeta] = []

    init(fallback: OutboundConfig = .direct) {
        self.fallback = fallback
    }

    func route(host: String, via outbound: OutboundConfig) {
        lock.withLock { byHost[host.lowercased()] = outbound }
    }

    var metas: [ConnectionMeta] { lock.withLock { seenMetas } }

    func decide(_ meta: ConnectionMeta) -> RouteDecision {
        lock.withLock {
            seenMetas.append(meta)
            let outbound = byHost[meta.host.lowercased()] ?? fallback
            return RouteDecision(policy: outbound.name,
                                 outbound: outbound,
                                 matchedRule: "test-rule",
                                 isBlocked: outbound.type == .reject)
        }
    }
}

/// Blocker double: exact or suffix matches.
final class StaticBlocker: DomainBlocking, @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [String: String] = [:]
    private var selectors: [String: [String]] = [:]

    init(blocked: [String: String] = [:], selectors: [String: [String]] = [:]) {
        self.reasons = blocked
        self.selectors = selectors
    }

    func block(_ domain: String, reason: String = "adblock") {
        lock.withLock { reasons[domain.lowercased()] = reason }
    }

    func verdict(for domain: String, thirdParty: Bool) -> BlockVerdict {
        let key = domain.lowercased()
        return lock.withLock {
            if let reason = reasons[key] { return BlockVerdict(blocked: true, reason: reason) }
            for (pattern, reason) in reasons where key.hasSuffix(pattern) {
                return BlockVerdict(blocked: true, reason: reason)
            }
            return .allow
        }
    }

    func cosmeticSelectors(for domain: String) -> [String] {
        lock.withLock { selectors[domain.lowercased()] ?? [] }
    }
}

// MARK: - Recorders

final class FlowCollector: FlowRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FlowEvent] = []

    func record(_ event: FlowEvent) {
        lock.withLock { storage.append(event) }
    }

    var events: [FlowEvent] { lock.withLock { storage } }
    var phases: [FlowPhase] { lock.withLock { storage.map(\.phase) } }

    func events(phase: FlowPhase) -> [FlowEvent] {
        lock.withLock { storage.filter { $0.phase == phase } }
    }

    func waitFor(phase: FlowPhase, count: Int = 1, timeout: TimeInterval = 5) async -> Bool {
        await waitUntil(timeout: timeout) { self.events(phase: phase).count >= count }
    }
}

final class CaptureCollector: CaptureSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CapturedRequest] = []

    func capture(_ request: CapturedRequest) {
        lock.withLock { storage.append(request) }
    }

    var requests: [CapturedRequest] { lock.withLock { storage } }

    func waitFor(count: Int = 1, timeout: TimeInterval = 5) async -> Bool {
        await waitUntil(timeout: timeout) { self.requests.count >= count }
    }
}

/// Resolver double: static host -> addresses.
final class MapResolver: NameResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: [String]]

    init(_ table: [String: [String]] = [:]) {
        self.table = table
    }

    func set(_ host: String, _ addresses: [String]) {
        lock.withLock { table[host.lowercased()] = addresses }
    }

    func resolve(_ host: String) async throws -> [String] {
        if NetAddress.isIPLiteral(host) { return [host] }
        let addresses = lock.withLock { table[host.lowercased()] }
        guard let addresses, !addresses.isEmpty else {
            throw LeapinError.connectionFailed("test resolver has no entry for \(host)")
        }
        return addresses
    }
}

// MARK: - Async helpers

@discardableResult
func waitUntil(timeout: TimeInterval = 5, poll: TimeInterval = 0.02, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
    }
    return condition()
}

/// Waits for an `NWListener` to become ready and returns the bound port.
///
/// The caller must install `newConnectionHandler` before calling this: Network
/// rejects a listener that starts without a handler.
func listenerPort(_ listener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
    try await withCheckedThrowingContinuation { continuation in
        let box = ContinuationBox(continuation)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue, port != 0 {
                    box.resume(returning: port)
                } else {
                    box.resume(throwing: LeapinError.connectionFailed("listener has no port"))
                }
            case .failed(let error):
                box.resume(throwing: error)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }
}

/// Resumes exactly one continuation, ignoring later listener state changes.
final class ContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        let pending = lock.withLock { () -> CheckedContinuation<T, Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        let pending = lock.withLock { () -> CheckedContinuation<T, Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(throwing: error)
    }
}

// MARK: - Raw echo server (byte pump target)

/// TCP server that echoes every received chunk back (optionally transformed).
final class EchoServer: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.echo")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private let transform: @Sendable (Data) -> Data

    private init(listener: NWListener, transform: @escaping @Sendable (Data) -> Data) {
        self.listener = listener
        self.transform = transform
    }

    static func start(transform: @escaping @Sendable (Data) -> Data = { $0 }) async throws -> EchoServer {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let listener = try NWListener(using: parameters, on: .any)
        let server = EchoServer(listener: listener, transform: transform)
        listener.newConnectionHandler = { connection in
            server.accept(connection)
        }
        server.port = try await listenerPort(listener, queue: server.queue)
        return server
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                connection.send(content: self.transform(data), completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveLoop(connection)
        }
    }

    func stop() {
        listener.cancel()
        for connection in lock.withLock({ connections }) {
            connection.cancel()
        }
        lock.withLock { connections.removeAll() }
    }
}

// MARK: - HTTP origin server

/// Minimal HTTP/1.1 origin used by the proxy tests.
final class HTTPOriginServer: @unchecked Sendable {
    enum Mode: Sendable {
        case echo
        case html(String)
        case status(Int, String)
    }

    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.http")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var requests: [HTTPRequestHead] = []
    private let mode: Mode

    private init(listener: NWListener, mode: Mode) {
        self.listener = listener
        self.mode = mode
    }

    static func start(mode: Mode = .echo) async throws -> HTTPOriginServer {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let listener = try NWListener(using: parameters, on: .any)
        let server = HTTPOriginServer(listener: listener, mode: mode)
        listener.newConnectionHandler = { connection in
            server.accept(connection)
        }
        server.port = try await listenerPort(listener, queue: server.queue)
        return server
    }

    var capturedRequests: [HTTPRequestHead] { lock.withLock { requests } }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        let socket = NetSocket(connection: connection, description: "origin")
        Task {
            do {
                try await socket.start(timeout: 5)
                let stream = BufferedStream(socket)
                while true {
                    guard let request = try await HTTPCodec.readRequestHead(stream) else { break }
                    self.lock.withLock { self.requests.append(request) }
                    let framing = try HTTPCodec.framing(for: request.headers, isRequest: true)
                    let body = try await HTTPCodec.readBody(stream, framing: framing)
                    let (status, contentType, payload) = self.response(for: request, body: body)
                    var headers = HTTPHeaders()
                    headers.set("Content-Type", contentType)
                    headers.set("Content-Length", String(payload.count))
                    let connectionHeader = (request.headers.first("Connection") ?? "").lowercased()
                    let keepAlive = !connectionHeader.contains("close")
                    headers.set("Connection", keepAlive ? "keep-alive" : "close")
                    var out = HTTPResponseHead(status: status, headers: headers).serialized
                    out.append(payload)
                    try await socket.write(out)
                    if !keepAlive { break }
                }
            } catch {
                // Origin-side failures are not asserted in these tests.
            }
            socket.close()
        }
    }

    private func response(for request: HTTPRequestHead,
                          body: Data) -> (Int, String, Data) {
        switch mode {
        case .echo:
            let object: [String: Any] = [
                "method": request.method,
                "target": request.target,
                "host": request.headers.first("Host") ?? "",
                "body": String(decoding: body, as: UTF8.self),
            ]
            let payload = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return (200, "application/json", payload)
        case .html(let html):
            return (200, "text/html; charset=utf-8", Data(html.utf8))
        case .status(let code, let message):
            return (code, "text/plain; charset=utf-8", Data(message.utf8))
        }
    }

    func stop() {
        listener.cancel()
        for connection in lock.withLock({ connections }) {
            connection.cancel()
        }
        lock.withLock { connections.removeAll() }
    }
}

// MARK: - Fake SOCKS5 / HTTP CONNECT upstreams

/// Minimal SOCKS5 server used to exercise `OutboundDialer`'s client side.
final class FakeSOCKS5Server: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.socks5upstream")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private let requireAuth: (String, String)?
    private var observedAuth: (String, String)?

    private init(listener: NWListener, requireAuth: (String, String)?) {
        self.listener = listener
        self.requireAuth = requireAuth
    }

    static func start(requireAuth: (String, String)? = nil) async throws -> FakeSOCKS5Server {
        let listener = try NWListener(using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options()), on: .any)
        let server = FakeSOCKS5Server(listener: listener, requireAuth: requireAuth)
        listener.newConnectionHandler = { connection in
            server.accept(connection)
        }
        server.port = try await listenerPort(listener, queue: server.queue)
        return server
    }

    var authSeen: (String, String)? { lock.withLock { observedAuth } }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        let socket = NetSocket(connection: connection, description: "socks5upstream")
        Task {
            do {
                try await socket.start(timeout: 5)
                let stream = BufferedStream(socket)
                let greeting = Array(try await stream.readExactly(2))
                let methods = Array(try await stream.readExactly(Int(greeting[1])))
                if let credentials = requireAuth {
                    guard methods.contains(SOCKS5.Method.userPass.rawValue) else {
                        try await stream.write(Data([0x05, 0xFF]))
                        socket.close()
                        return
                    }
                    try await stream.write(Data([0x05, SOCKS5.Method.userPass.rawValue]))
                    let version = try await stream.readExactly(1)
                    guard Array(version).first == 0x01 else { socket.close(); return }
                    let userLength = Int(Array(try await stream.readExactly(1))[0])
                    let user = String(decoding: try await stream.readExactly(userLength), as: UTF8.self)
                    let passLength = Int(Array(try await stream.readExactly(1))[0])
                    let pass = String(decoding: try await stream.readExactly(passLength), as: UTF8.self)
                    lock.withLock { self.observedAuth = (user, pass) }
                    let ok = user == credentials.0 && pass == credentials.1
                    try await stream.write(Data([0x01, ok ? 0x00 : 0x01]))
                    if !ok { socket.close(); return }
                } else {
                    guard methods.contains(SOCKS5.Method.noAuth.rawValue) else {
                        try await stream.write(Data([0x05, 0xFF]))
                        socket.close()
                        return
                    }
                    try await stream.write(Data([0x05, SOCKS5.Method.noAuth.rawValue]))
                }

                _ = try await stream.readExactly(1) // version
                _ = try await stream.readExactly(1) // command
                _ = try await stream.readExactly(1) // reserved
                let target = try await SOCKS5.decodeAddress(stream)
                let upstream = try await NetSocket.connect(host: target.host,
                                                           port: target.port,
                                                           timeout: 5,
                                                           tls: nil)
                try await stream.write(SOCKS5.encodeReply(.succeeded))
                _ = await BytePump.run(socket, upstream, idleTimeout: 20)
            } catch {
                socket.close()
            }
        }
    }

    func stop() {
        listener.cancel()
        for connection in lock.withLock({ connections }) { connection.cancel() }
        lock.withLock { connections.removeAll() }
    }
}

/// Minimal HTTP CONNECT upstream used to exercise `OutboundDialer`'s HTTP path.
final class FakeHTTPConnectServer: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.httpupstream")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var seenHeaders: [HTTPHeaders] = []

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func start() async throws -> FakeHTTPConnectServer {
        let listener = try NWListener(using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options()), on: .any)
        let server = FakeHTTPConnectServer(listener: listener)
        listener.newConnectionHandler = { connection in
            server.accept(connection)
        }
        server.port = try await listenerPort(listener, queue: server.queue)
        return server
    }

    var authorizationHeaders: [String?] {
        lock.withLock { seenHeaders.map { $0.first("Proxy-Authorization") } }
    }

    var targetAuthorities: [String] {
        lock.withLock { seenHeaders.map { $0.first("Host") ?? "" } }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        let socket = NetSocket(connection: connection, description: "httpupstream")
        Task {
            do {
                try await socket.start(timeout: 5)
                let stream = BufferedStream(socket)
                guard let request = try await HTTPCodec.readRequestHead(stream) else { return }
                lock.withLock { self.seenHeaders.append(request.headers) }
                guard request.isConnect, let authority = request.targetAuthority(defaultPort: 443) else {
                    try await stream.write(Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n".utf8))
                    socket.close()
                    return
                }
                let upstream = try await NetSocket.connect(host: authority.host,
                                                           port: authority.port,
                                                           timeout: 5,
                                                           tls: nil)
                try await stream.write(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
                _ = await BytePump.run(socket, upstream, idleTimeout: 20)
            } catch {
                socket.close()
            }
        }
    }

    func stop() {
        listener.cancel()
        for connection in lock.withLock({ connections }) { connection.cancel() }
        lock.withLock { connections.removeAll() }
    }
}

// MARK: - Fake DNS upstream (UDP)

/// UDP DNS server that answers from a closure and counts queries.
final class FakeDNSServer: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.dns")
    private let lock = NSLock()
    private var queryCountStorage = 0
    private let responder: @Sendable (DNSMessage) -> DNSMessage?

    private init(listener: NWListener, responder: @escaping @Sendable (DNSMessage) -> DNSMessage?) {
        self.listener = listener
        self.responder = responder
    }

    static func start(responder: @escaping @Sendable (DNSMessage) -> DNSMessage?) async throws -> FakeDNSServer {
        let parameters = NWParameters(dtls: nil, udp: NWProtocolUDP.Options())
        let listener = try NWListener(using: parameters, on: .any)
        let server = FakeDNSServer(listener: listener, responder: responder)
        listener.newConnectionHandler = { connection in
            connection.start(queue: server.queue)
            server.receiveLoop(connection)
        }
        server.port = try await listenerPort(listener, queue: server.queue)
        return server
    }

    var queryCount: Int { lock.withLock { queryCountStorage } }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { data, _, _, error in
            if let data, !data.isEmpty {
                self.lock.withLock { self.queryCountStorage += 1 }
                if let query = try? DNSMessage.decode(data),
                   let reply = self.responder(query) {
                    connection.send(content: reply.encode(), completion: .contentProcessed { _ in })
                }
            }
            if error == nil {
                self.receiveLoop(connection)
            } else {
                connection.cancel()
            }
        }
    }

    func stop() {
        listener.cancel()
    }
}

// MARK: - Raw SOCKS5 client helper

/// Hand-rolled SOCKS5 client used to drive `ProxyServer` byte by byte.
struct RawSOCKS5Client {
    let socket: NetSocket
    let stream: BufferedStream

    static func connect(to proxyPort: UInt16,
                        host: String,
                        port: UInt16,
                        timeout: TimeInterval = 5,
                        hostOverride: String = "127.0.0.1") async throws -> RawSOCKS5Client {
        let socket = try await NetSocket.connect(host: hostOverride, port: proxyPort, timeout: timeout, tls: nil)
        let stream = BufferedStream(socket)
        try await stream.write(Data([0x05, 0x01, 0x00]))
        let method = Array(try await stream.readExactly(2))
        guard method == [0x05, 0x00] else {
            socket.close()
            throw LeapinError.protocolError("socks5 client: method negotiation returned \(method)")
        }
        guard let request = SOCKS5.requestHeader(host: host, port: port) else {
            socket.close()
            throw LeapinError.invalidConfiguration("socks5 client: cannot encode \(host):\(port)")
        }
        try await stream.write(request)
        let reply = Array(try await stream.readExactly(4))
        guard reply[0] == 0x05, reply[1] == 0x00 else {
            socket.close()
            throw LeapinError.protocolError("socks5 client: CONNECT failed \(reply)")
        }
        switch reply[3] {
        case SOCKS5.AddressType.ipv4.rawValue:
            _ = try await stream.readExactly(6)
        case SOCKS5.AddressType.ipv6.rawValue:
            _ = try await stream.readExactly(18)
        case SOCKS5.AddressType.domain.rawValue:
            let length = Int(Array(try await stream.readExactly(1))[0])
            _ = try await stream.readExactly(length + 2)
        default:
            break
        }
        return RawSOCKS5Client(socket: socket, stream: stream)
    }

    func close() { socket.close() }
}
