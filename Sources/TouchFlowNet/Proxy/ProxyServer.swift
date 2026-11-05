import Foundation
import Network
import TouchFlowCore

/// Single-port local proxy front-end.
///
/// Sniffs the first byte of every accepted connection: `0x05` is handled as
/// SOCKS5 (RFC 1928, no authentication), anything else is parsed as HTTP/1.1
/// (`CONNECT host:port` for tunnels, absolute-form requests forwarded as plain
/// HTTP). Each client is handled on its own Task, block decisions come from the
/// injected `RouteDeciding` / `DomainBlocking` implementations, and traffic is
/// pumped through `BytePump` while `FlowEvent`s are reported.
public final class ProxyServer: @unchecked Sendable {
    public struct Options: Sendable {
        public var port: UInt16
        public var allowLAN: Bool
        public var enableSOCKS5: Bool
        public var enableHTTP: Bool
        public var mitm: Bool
        public var mitmHosts: [String]

        public init(port: UInt16,
                    allowLAN: Bool = false,
                    enableSOCKS5: Bool = true,
                    enableHTTP: Bool = true,
                    mitm: Bool = false,
                    mitmHosts: [String] = ["*"]) {
            self.port = port
            self.allowLAN = allowLAN
            self.enableSOCKS5 = enableSOCKS5
            self.enableHTTP = enableHTTP
            self.mitm = mitm
            self.mitmHosts = mitmHosts
        }
    }

    public static let idleTimeout: TimeInterval = 300

    public let options: Options

    private let router: RouteDeciding
    private let resolver: NameResolving
    private let blocker: DomainBlocking?
    private let flows: FlowRecording?
    private let capture: CaptureSink?
    private let ca: CertificateAuthority?
    private let dialer: OutboundDialer
    private let queue = DispatchQueue(label: "com.touchflow.proxy", qos: .userInitiated)

    private let lock = NSLock()
    private var listener: NWListener?
    private var running = false
    private var boundPort: UInt16
    private var activeCount = 0
    private var clientSockets: [UUID: NetSocket] = [:]
    private var clientTasks: [UUID: Task<Void, Never>] = [:]
    /// Upstream sockets dialed on behalf of a client. Registered so `stop()` can close
    /// them; without this a stopped proxy keeps upstream FDs (and the pump blocked on
    /// them) alive until the 300 s idle timeout fires.
    private var clientUpstreams: [UUID: ByteStream] = [:]

    public init(options: Options,
                router: RouteDeciding,
                resolver: NameResolving,
                blocker: DomainBlocking?,
                flows: FlowRecording?,
                capture: CaptureSink?,
                ca: CertificateAuthority? = nil) {
        self.options = options
        self.router = router
        self.resolver = resolver
        self.blocker = blocker
        self.flows = flows
        self.capture = capture
        self.ca = ca
        self.dialer = OutboundDialer(resolver: resolver)
        self.boundPort = options.port
    }

    // MARK: - Lifecycle

    public var isRunning: Bool { lock.withLock { running } }

    public var activeConnections: Int { lock.withLock { activeCount } }

    /// Port the listener actually bound to (resolves `port: 0`).
    public var listeningPort: UInt16 { lock.withLock { boundPort } }

    public func start() throws {
        if isRunning {
            throw TouchFlowError.invalidConfiguration("proxy server already running on port \(boundPort)")
        }
        guard let nwPort = NWEndpoint.Port(rawValue: options.port) else {
            throw TouchFlowError.invalidConfiguration("invalid proxy port \(options.port)")
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: options.allowLAN ? .ipv4(.any) : .ipv4(.loopback),
            port: nwPort)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw TouchFlowError.connectionFailed(
                "cannot create proxy listener on port \(options.port): \(error.localizedDescription)")
        }

        let gate = StartGate()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                gate.succeed()
            case .failed(let error):
                gate.fail(error)
            case .cancelled:
                gate.fail(TouchFlowError.connectionFailed("proxy listener on port \(self.options.port) was cancelled during start"))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        let outcome = gate.wait(timeout: 5)
        switch outcome {
        case .ready:
            break
        case .failure(let error):
            listener.cancel()
            let detail = error.localizedDescription
            if Self.isAddressInUse(error) {
                throw TouchFlowError.connectionFailed(
                    "proxy port \(options.port) is already in use (\(detail)); choose another port or stop the other process")
            }
            throw TouchFlowError.connectionFailed("proxy listener failed on port \(options.port): \(detail)")
        case .timeout:
            listener.cancel()
            throw TouchFlowError.connectionFailed("proxy listener on port \(options.port) did not become ready in time")
        }

        lock.withLock {
            self.listener = listener
            self.running = true
            if let port = listener.port?.rawValue { self.boundPort = port }
        }
        TFLog.shared.info("net.proxy",
            "listening on 127.0.0.1:\(listeningPort) (allowLAN=\(options.allowLAN), socks5=\(options.enableSOCKS5), http=\(options.enableHTTP), mitm=\(options.mitm))")
    }

    public func stop() {
        let snapshot: (NWListener?, [(UUID, NetSocket)], [UUID: Task<Void, Never>], [UUID: ByteStream]) = lock.withLock {
            let l = self.listener
            let sockets = Array(self.clientSockets)
            let tasks = self.clientTasks
            let upstreams = self.clientUpstreams
            self.listener = nil
            self.running = false
            self.clientSockets.removeAll()
            self.clientTasks.removeAll()
            self.clientUpstreams.removeAll()
            self.activeCount = 0
            return (l, sockets, tasks, upstreams)
        }
        snapshot.0?.cancel()
        for (_, socket) in snapshot.1 { socket.close() }
        for (_, task) in snapshot.2 { task.cancel() }
        // Client sockets and pumps own their upstream only while the client lives, so
        // close the upstreams explicitly — cancelling the task alone leaves the pump
        // blocked on a read that never returns.
        for (_, upstream) in snapshot.3 { upstream.close() }
        if snapshot.0 != nil {
            TFLog.shared.info("net.proxy", "stopped listener on port \(listeningPort)")
        }
    }

    // MARK: - Accept loop

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let remote = Self.hostString(connection.endpoint)
        let socket = NetSocket(connection: connection,
                               description: "client \(remote ?? "unknown")")
        lock.withLock {
            clientSockets[id] = socket
            activeCount += 1
        }
        let task = Task { [weak self] in
            guard let self else {
                socket.close()
                return
            }
            await self.handleClient(id: id, socket: socket, remote: remote)
        }
        lock.withLock { clientTasks[id] = task }
    }

    private func release(id: UUID) {
        let socket = lock.withLock { () -> NetSocket? in
            let s = clientSockets.removeValue(forKey: id)
            clientTasks.removeValue(forKey: id)
            activeCount = max(0, activeCount - 1)
            return s
        }
        socket?.close()
    }

    /// Tracks the upstream currently used by `id` so `stop()` can close it. A plain
    /// HTTP client dials one upstream per request; registering closes any predecessor.
    private func registerUpstream(_ upstream: ByteStream, for id: UUID) {
        let previous = lock.withLock { () -> ByteStream? in
            let old = clientUpstreams[id]
            clientUpstreams[id] = upstream
            return old
        }
        previous?.close()
    }

    /// Forgets (and closes) the upstream of `id`. Closing twice is safe: every
    /// `ByteStream` implementation treats `close()` as idempotent.
    private func releaseUpstream(for id: UUID) {
        let upstream = lock.withLock { () -> ByteStream? in
            clientUpstreams.removeValue(forKey: id)
        }
        upstream?.close()
    }

    // MARK: - Client dispatch

    private func handleClient(id: UUID, socket: NetSocket, remote: String?) async {
        defer { release(id: id) }

        if !options.allowLAN, let remote, !Self.isLocalAddress(remote) {
            TFLog.shared.warn("net.proxy",
                "rejected non-local client \(remote): allowLAN is disabled")
            socket.close()
            return
        }

        do {
            try await socket.start(timeout: 15)
        } catch {
            TFLog.shared.warn("net.proxy", "client handshake failed: \(error.localizedDescription)")
            socket.close()
            return
        }

        let stream = BufferedStream(socket)
        do {
            guard let first = try await stream.readByte() else {
                TFLog.shared.debug("net.proxy", "client closed before sending data")
                socket.close()
                return
            }
            if first == SOCKS5.version {
                guard options.enableSOCKS5 else {
                    TFLog.shared.warn("net.proxy", "SOCKS5 client rejected: SOCKS5 disabled")
                    try? await stream.write(SOCKS5.encodeReply(.commandNotSupported))
                    socket.close()
                    return
                }
                // handleSOCKS5 re-reads the version byte, so hand it back first.
                stream.pushBack(Data([first]))
                try await handleSOCKS5(id: id, stream: stream, socket: socket, remote: remote)
            } else {
                stream.pushBack(Data([first]))
                guard options.enableHTTP else {
                    TFLog.shared.warn("net.proxy", "HTTP client rejected: HTTP proxy disabled")
                    try? await writePlainHTTP(socket,
                                              status: 501,
                                              reason: "Not Implemented",
                                              message: "HTTP proxy is disabled on this TouchFlow instance")
                    socket.close()
                    return
                }
                try await handleHTTP(id: id, stream: stream, socket: socket, remote: remote)
            }
        } catch {
            TFLog.shared.warn("net.proxy", "client session ended: \(error.localizedDescription)")
        }
        socket.close()
    }

    // MARK: - HTTP

    private func handleHTTP(id: UUID, stream: BufferedStream, socket: NetSocket, remote: String?) async throws {
        while true {
            guard let request = try await HTTPCodec.readRequestHead(stream) else { return }
            if request.isConnect {
                await handleCONNECT(id: id, request: request, stream: stream, socket: socket, remote: remote)
                return
            }
            let keepAlive = try await forwardPlainHTTP(id: id, request: request, stream: stream, socket: socket)
            if !keepAlive { return }
        }
    }

    private func handleCONNECT(id: UUID, request: HTTPRequestHead, stream: BufferedStream, socket: NetSocket, remote: String?) async {
        guard let authority = request.targetAuthority(defaultPort: 443) else {
            try? await writePlainHTTP(socket, status: 400, reason: "Bad Request",
                                      message: "TouchFlow could not parse CONNECT target \(request.target)")
            return
        }
        let meta = ConnectionMeta(host: authority.host,
                                  port: authority.port,
                                  network: "tcp",
                                  sourceApp: nil,
                                  sourcePID: nil)
        let decision = router.decide(meta)

        if decision.isBlocked || decision.outbound.type == .reject {
            recordRejected(meta, decision: decision, blockedBy: "rule")
            try? await writePlainHTTP(socket, status: 403, reason: "Forbidden",
                                      message: "TouchFlow blocked \(authority.host):\(authority.port) (rule \(decision.matchedRule ?? "reject"))")
            return
        }
        if let blocker, blocker.verdict(for: authority.host, thirdParty: false).blocked {
            let verdict = blocker.verdict(for: authority.host, thirdParty: false)
            recordRejected(meta, decision: decision, blockedBy: "adblock")
            TFLog.shared.info("net.proxy", "blocked \(authority.host):\(authority.port): \(verdict.reason ?? "adblock")")
            try? await writePlainHTTP(socket, status: 403, reason: "Forbidden",
                                      message: "TouchFlow blocked \(authority.host) (\(verdict.reason ?? "adblock"))")
            return
        }

        // The head was read through a BufferedStream that may have over-read into the
        // tunnel payload (a TLS ClientHello often arrives right after the CONNECT is
        // answered). Hand those bytes back to the socket before anything pumps it.
        let leftover = stream.drainBuffer()
        if !leftover.isEmpty {
            TFLog.shared.debug("net.proxy", "handing \(leftover.count) buffered byte(s) to tunnel for \(authority.host):\(authority.port)")
            socket.unread(leftover)
        }

        if options.mitm, let ca,
           HostGlob.matchesAny(authority.host, patterns: options.mitmHosts) {
            TFLog.shared.info("net.proxy", "MITM \(authority.host):\(authority.port)")
            let handler = MITMHandler(ca: ca,
                                      blocker: blocker,
                                      capture: capture,
                                      dialer: dialer,
                                      connectHost: authority.host,
                                      connectPort: authority.port,
                                      outbound: decision.outbound,
                                      sourceApp: meta.sourceApp,
                                      sourcePID: meta.sourcePID,
                                      idleTimeout: Self.idleTimeout)
            await handler.run(client: socket)
            return
        }

        await tunnel(id: id, authority: authority, meta: meta, decision: decision, socket: socket)
    }

    /// Establishes the CONNECT tunnel and pumps bytes until either side finishes.
    private func tunnel(id: UUID,
                        authority: (host: String, port: UInt16),
                        meta: ConnectionMeta,
                        decision: RouteDecision,
                        socket: NetSocket) async {
        let started = Date()
        do {
            let upstream = try await dialer.connect(via: decision.outbound,
                                                    host: authority.host,
                                                    port: authority.port)
            registerUpstream(upstream, for: id)
            defer { releaseUpstream(for: id) }
            try await socket.write(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            flows?.record(makeEvent(phase: .opened, meta: meta, decision: decision,
                                    bytesIn: 0, bytesOut: 0, durationMs: 0))
            let stats = await BytePump.run(socket, upstream, idleTimeout: Self.idleTimeout)
            flows?.record(makeEvent(phase: .closed, meta: meta, decision: decision,
                                    bytesIn: stats.bytesIn,
                                    bytesOut: stats.bytesOut,
                                    durationMs: max(stats.durationMs, elapsedMs(since: started))))
            TFLog.shared.debug("net.proxy",
                "tunnel \(authority.host):\(authority.port) closed in=\(stats.bytesIn) out=\(stats.bytesOut)")
        } catch {
            flows?.record(makeEvent(phase: .failed, meta: meta, decision: decision,
                                    bytesIn: 0, bytesOut: 0,
                                    durationMs: elapsedMs(since: started)))
            TFLog.shared.warn("net.proxy",
                "tunnel \(authority.host):\(authority.port) via \(decision.outbound.name) failed: \(error.localizedDescription)")
            try? await writePlainHTTP(socket, status: 502, reason: "Bad Gateway",
                                      message: "TouchFlow could not reach \(authority.host):\(authority.port): \(error.localizedDescription)")
        }
    }

    /// Forwards one absolute-URI plain HTTP request. Returns whether the client
    /// connection may be reused.
    private func forwardPlainHTTP(id: UUID,
                                  request: HTTPRequestHead,
                                  stream: BufferedStream,
                                  socket: NetSocket) async throws -> Bool {
        let framing = try HTTPCodec.framing(for: request.headers, isRequest: true)
        let body = try await HTTPCodec.readBody(stream, framing: framing)

        guard let authority = request.targetAuthority(defaultPort: 80) else {
            try await writePlainHTTP(socket, status: 400, reason: "Bad Request",
                                     message: "TouchFlow could not parse request target \(request.target)")
            return false
        }
        let meta = ConnectionMeta(host: authority.host, port: authority.port, network: "tcp")
        let decision = router.decide(meta)
        let started = Date()

        if decision.isBlocked || decision.outbound.type == .reject {
            recordRejected(meta, decision: decision, blockedBy: "rule")
            recordBlockedCapture(host: authority.host, url: request.target,
                                 method: request.method.uppercased(), request: request)
            try await writePlainHTTP(socket, status: 403, reason: "Forbidden",
                                     message: "TouchFlow blocked \(authority.host)")
            return false
        }
        if let blocker, blocker.verdict(for: authority.host, path: request.target, thirdParty: false).blocked {
            recordRejected(meta, decision: decision, blockedBy: "adblock")
            recordBlockedCapture(host: authority.host, url: request.target,
                                 method: request.method.uppercased(), request: request)
            try await writePlainHTTP(socket, status: 403, reason: "Forbidden",
                                     message: "TouchFlow blocked \(authority.host)")
            return false
        }

        let upstream: ByteStream
        do {
            upstream = try await dialer.connect(via: decision.outbound,
                                                host: authority.host,
                                                port: authority.port)
        } catch {
            flows?.record(makeEvent(phase: .failed, meta: meta, decision: decision,
                                    bytesIn: 0, bytesOut: 0, durationMs: elapsedMs(since: started)))
            try await writePlainHTTP(socket, status: 502, reason: "Bad Gateway",
                                     message: "TouchFlow could not reach \(authority.host):\(authority.port)")
            return false
        }
        registerUpstream(upstream, for: id)
        defer { releaseUpstream(for: id) }
        flows?.record(makeEvent(phase: .opened, meta: meta, decision: decision,
                                bytesIn: 0, bytesOut: 0, durationMs: 0))

        do {
            let upstreamStream = BufferedStream(upstream)
            var headers = HTTPCodec.stripHopByHop(request.headers)
            headers.remove("Proxy-Authorization")
            headers.set("Host", authority.port == 80 ? authority.host : "\(authority.host):\(authority.port)")
            var payload = body
            _ = HTTPCodec.serialize(body: payload, headers: &headers)
            if request.method.uppercased() == "HEAD" {
                headers.remove("Content-Length")
                payload = Data()
            }
            let forwarded = HTTPRequestHead(method: request.method,
                                            target: HTTPCodec.originFormTarget(request.target),
                                            headers: headers)
            var bytes = forwarded.serialized()
            bytes.append(payload)
            try await upstream.write(bytes)

            guard let response = try await HTTPCodec.readResponseHead(upstreamStream) else {
                throw TouchFlowError.connectionFailed("origin closed without a response")
            }
            let responseBody = try await readResponseBody(response, request: request, stream: upstreamStream)
            recordPlainCapture(host: authority.host, request: request, requestBody: body,
                               response: response, responseBody: responseBody,
                               durationMs: elapsedMs(since: started))

            var responseHeaders = HTTPCodec.stripHopByHop(response.headers)
            if request.method.uppercased() != "HEAD" {
                _ = HTTPCodec.serialize(body: responseBody, headers: &responseHeaders)
            }
            responseHeaders.set("Connection", "keep-alive")
            let head = HTTPResponseHead(status: response.status, reason: response.reason, headers: responseHeaders)
            var out = head.serialized
            out.append(responseBody)
            try await socket.write(out)

            flows?.record(makeEvent(phase: .closed, meta: meta, decision: decision,
                                    bytesIn: body.count, bytesOut: out.count,
                                    durationMs: elapsedMs(since: started)))
            let clientWantsClose = (request.headers.first("Connection") ?? "").lowercased().contains("close")
            return !clientWantsClose
        } catch {
            flows?.record(makeEvent(phase: .failed, meta: meta, decision: decision,
                                    bytesIn: body.count, bytesOut: 0,
                                    durationMs: elapsedMs(since: started)))
            TFLog.shared.warn("net.proxy",
                "HTTP \(request.method) \(authority.host) failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Capture (plain HTTP)

    /// Plain HTTP is not decrypted, but header/body pairs are still worth recording
    /// when the user enabled HTTP capture: the Capture page then also shows
    /// unencrypted traffic and every blocked ad request.
    private func recordPlainCapture(host: String,
                                    request: HTTPRequestHead,
                                    requestBody: Data,
                                    response: HTTPResponseHead,
                                    responseBody: Data,
                                    durationMs: Int) {
        guard let capture else { return }
        capture.capture(CapturedRequest(
            method: request.method.uppercased(),
            url: request.target,
            host: host,
            requestHeaders: Self.headerDictionary(request.headers),
            requestBody: Self.captureBody(requestBody),
            statusCode: response.status,
            responseHeaders: Self.headerDictionary(response.headers),
            responseBody: Self.captureBody(responseBody),
            mimeType: response.headers.first("Content-Type"),
            durationMs: durationMs))
    }

    private func recordBlockedCapture(host: String, url: String, method: String, request: HTTPRequestHead) {
        guard let capture else { return }
        capture.capture(CapturedRequest(method: method,
                                        url: url,
                                        host: host,
                                        requestHeaders: Self.headerDictionary(request.headers),
                                        statusCode: 403,
                                        blocked: true))
    }

    private static func headerDictionary(_ headers: HTTPHeaders) -> [String: String] {
        Dictionary(headers.items.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private static func captureBody(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        return data.count > 262_144 ? Data(data.prefix(262_144)) : data
    }

    // MARK: - SOCKS5

    private func handleSOCKS5(id: UUID, stream: BufferedStream, socket: NetSocket, remote: String?) async throws {
        guard let greeting = try await stream.readExactly(2).nilIfEmpty else {
            throw TouchFlowError.protocolError("socks5: client closed during method negotiation")
        }
        let greetingBytes = Array(greeting)
        guard greetingBytes[0] == SOCKS5.version else {
            throw TouchFlowError.protocolError("socks5: bad version \(greetingBytes[0])")
        }
        let methodCount = Int(greetingBytes[1])
        let methods = methodCount > 0 ? Array(try await stream.readExactly(methodCount)) : []
        guard methods.contains(SOCKS5.Method.noAuth.rawValue) else {
            try await stream.write(SOCKS5.encodeReply(.generalFailure))
            TFLog.shared.warn("net.proxy", "socks5 client offered no supported auth method")
            return
        }
        try await stream.write(Data([SOCKS5.version, SOCKS5.Method.noAuth.rawValue]))

        guard let requestHeadData = try await stream.readExactly(3).nilIfEmpty else {
            throw TouchFlowError.protocolError("socks5: client closed before request")
        }
        let requestHead = Array(requestHeadData)
        guard requestHead[0] == SOCKS5.version else {
            throw TouchFlowError.protocolError("socks5: bad request version \(requestHead[0])")
        }
        guard requestHead[2] == 0x00 else {
            throw TouchFlowError.protocolError("socks5: reserved byte is not zero")
        }
        let command = requestHead[1]
        let (host, port) = try await SOCKS5.decodeAddress(stream)

        guard command == SOCKS5.Command.connect.rawValue else {
            TFLog.shared.warn("net.proxy", "socks5 unsupported command \(command) for \(host):\(port)")
            try await stream.write(SOCKS5.encodeReply(.commandNotSupported))
            return
        }

        let meta = ConnectionMeta(host: host, port: port, network: "tcp")
        let decision = router.decide(meta)
        if decision.isBlocked || decision.outbound.type == .reject {
            recordRejected(meta, decision: decision, blockedBy: "rule")
            try await stream.write(SOCKS5.encodeReply(.notAllowed))
            return
        }
        if let blocker, blocker.verdict(for: host, thirdParty: false).blocked {
            recordRejected(meta, decision: decision, blockedBy: "adblock")
            TFLog.shared.info("net.proxy", "socks5 blocked \(host):\(port)")
            try await stream.write(SOCKS5.encodeReply(.notAllowed))
            return
        }

        let started = Date()
        do {
            let upstream = try await dialer.connect(via: decision.outbound, host: host, port: port)
            registerUpstream(upstream, for: id)
            defer { releaseUpstream(for: id) }
            try await stream.write(SOCKS5.encodeReply(.succeeded))
            // Early client payload may already sit in the handshake's BufferedStream.
            let leftover = stream.drainBuffer()
            if !leftover.isEmpty { socket.unread(leftover) }
            flows?.record(makeEvent(phase: .opened, meta: meta, decision: decision,
                                    bytesIn: 0, bytesOut: 0, durationMs: 0))
            let stats = await BytePump.run(socket, upstream, idleTimeout: Self.idleTimeout)
            flows?.record(makeEvent(phase: .closed, meta: meta, decision: decision,
                                    bytesIn: stats.bytesIn,
                                    bytesOut: stats.bytesOut,
                                    durationMs: max(stats.durationMs, elapsedMs(since: started))))
        } catch {
            flows?.record(makeEvent(phase: .failed, meta: meta, decision: decision,
                                    bytesIn: 0, bytesOut: 0, durationMs: elapsedMs(since: started)))
            TFLog.shared.warn("net.proxy",
                "socks5 \(host):\(port) via \(decision.outbound.name) failed: \(error.localizedDescription)")
            try? await stream.write(SOCKS5.encodeReply(.hostUnreachable))
        }
    }

    // MARK: - Shared helpers

    private func readResponseBody(_ response: HTTPResponseHead,
                                  request: HTTPRequestHead,
                                  stream: BufferedStream) async throws -> Data {
        if request.method.uppercased() == "HEAD" { return Data() }
        if response.status == 204 || response.status == 304 || (100..<200).contains(response.status) {
            return Data()
        }
        let hasLength = response.headers.contains("Content-Length")
        let hasTransfer = response.headers.contains("Transfer-Encoding")
        if !hasLength && !hasTransfer {
            var body = Data()
            while let chunk = try await stream.readSome(maxLength: 16 * 1024) {
                body.append(chunk)
                if body.count > HTTPCodec.bodyLimit {
                    throw TouchFlowError.protocolError("response body exceeds limit")
                }
            }
            return body
        }
        return try await HTTPCodec.readBody(stream, framing: try HTTPCodec.framing(for: response.headers, isRequest: false))
    }

    private func makeEvent(phase: FlowPhase,
                           meta: ConnectionMeta,
                           decision: RouteDecision,
                           bytesIn: Int,
                           bytesOut: Int,
                           durationMs: Int,
                           blockedBy: String? = nil) -> FlowEvent {
        FlowEvent(phase: phase,
                  host: meta.host,
                  port: meta.port,
                  network: meta.network,
                  policy: decision.policy,
                  matchedRule: decision.matchedRule,
                  outbound: decision.outbound.name,
                  sourceApp: meta.sourceApp,
                  sourcePID: meta.sourcePID,
                  bytesIn: bytesIn,
                  bytesOut: bytesOut,
                  durationMs: durationMs,
                  blockedBy: blockedBy)
    }

    private func recordRejected(_ meta: ConnectionMeta, decision: RouteDecision, blockedBy: String) {
        flows?.record(makeEvent(phase: .rejected, meta: meta, decision: decision,
                                bytesIn: 0, bytesOut: 0, durationMs: 0, blockedBy: blockedBy))
        TFLog.shared.info("net.proxy", "rejected \(meta.host):\(meta.port) (\(blockedBy))")
    }

    private func writePlainHTTP(_ socket: NetSocket,
                                status: Int,
                                reason: String,
                                message: String) async throws {
        let payload = Data((message + "\n").utf8)
        var headers = HTTPHeaders()
        headers.set("Content-Type", "text/plain; charset=utf-8")
        headers.set("Content-Length", String(payload.count))
        headers.set("Connection", "close")
        var data = HTTPResponseHead(status: status, reason: reason, headers: headers).serialized
        data.append(payload)
        try await socket.write(data)
    }

    private func elapsedMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    // MARK: - Address helpers

    private static func hostString(_ endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address): return "\(address)"
            case .ipv6(let address): return "\(address)"
            case .name(let name, _): return name
            @unknown default: return nil
            }
        case .service(let name, _, _, _):
            return name
        default:
            return nil
        }
    }

    static func isLocalAddress(_ host: String) -> Bool {
        let normalized = host.hasPrefix("::ffff:") ? String(host.dropFirst(7)) : host
        if normalized == "::1" || normalized == "localhost" { return true }
        if let v4 = NetAddress.ipv4Bytes(normalized), let first = v4.first {
            if first == 127 { return true }
            if first == 10 { return true }
            if first == 192, v4.count > 1, v4[1] == 168 { return true }
            if first == 172, v4.count > 1, v4[1] >= 16, v4[1] < 32 { return true }
            if first == 169, v4.count > 1, v4[1] == 254 { return true }
            return false
        }
        let lower = normalized.lowercased()
        if lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd") {
            return true
        }
        return false
    }

    private static func isAddressInUse(_ error: Error) -> Bool {
        if let nwError = error as? NWError, case .posix(let code) = nwError {
            return code == .EADDRINUSE
        }
        if let posix = error as? POSIXError, posix.code == .EADDRINUSE {
            return true
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("address already in use") || text.contains("in use")
    }
}

// MARK: - Start synchronisation

/// Bridges the asynchronous `NWListener` state callback into a synchronous `start()`.
private final class StartGate: @unchecked Sendable {
    enum Outcome {
        case ready
        case failure(Error)
        case timeout
    }

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outcome: Outcome?
    private var claimed = false

    func succeed() {
        finish(.ready)
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ outcome: Outcome) {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !claimed else { return false }
            claimed = true
            self.outcome = outcome
            return true
        }
        if shouldSignal { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) -> Outcome {
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            let settled = lock.withLock { claimed }
            if !settled { return .timeout }
        }
        return lock.withLock { outcome ?? .timeout }
    }
}

private extension Data {
    var nilIfEmpty: Data? { isEmpty ? nil : self }
}
