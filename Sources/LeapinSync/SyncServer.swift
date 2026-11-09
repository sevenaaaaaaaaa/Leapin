import Foundation
import Network
import LeapinCore
import Darwin

// MARK: - Announce envelope (wire superset)
//
// The wire contract advertises versions as metadata only. To let two devices
// converge inside a single sync round, the client may attach the canonical
// bytes for versions the peer reported as missing. The envelope is a superset
// of AnnounceRequest, so a plain AnnounceRequest body still decodes.

struct SyncAnnounceEnvelope: Codable, Sendable {
    var device: SyncDevice
    var pointers: [String: ActivePointer]
    var versions: [ProfileVersion]
    /// base64(canonical profile JSON), keyed by version id. Present only when
    /// the sender knows the peer needs that version.
    var contents: [String: String]?

    init(device: SyncDevice, pointers: [String: ActivePointer],
         versions: [ProfileVersion], contents: [String: String]? = nil) {
        self.device = device
        self.pointers = pointers
        self.versions = versions
        self.contents = contents
    }
}

// MARK: - Sync server
//
// Plaintext HTTP/1.1 over the LAN, authenticated per request with the Ed25519
// envelope from SyncAuth. Every route except /v1/info and /v1/pair requires a
// paired peer signature; the pairing code is the only secret on the wire and
// it is short-lived and single-use.

public final class SyncServer: @unchecked Sendable {
    public static let maxBodyBytes = 4 << 20
    public static let maxHeaderBytes = 64 << 10
    public static let pairingCodeTTL: TimeInterval = 300
    static let nonceTTL: TimeInterval = 600
    static let nonceLimit = 8192

    public let identity: DeviceIdentity
    public let store: ProfileVersionStore
    public let peers: PeerRegistry
    /// Token source for the read-only /panel routes. Read per request so a
    /// rotation on disk takes effect without restarting the server. nil
    /// disables the panel entirely.
    private let panelTokenProvider: (@Sendable () -> String?)?
    /// The token currently offered to browsers (nil when the panel is off).
    public var panelToken: String? { panelTokenProvider?() }
    /// Optional local "applied" marker shown by the panel. The sync module has
    /// no engine, so the caller owns this fact.
    private let appliedVersionProvider: (@Sendable () -> String?)?
    /// Port requested at init; 0 means "let the system pick one".
    public let requestedPort: UInt16
    public let bindLAN: Bool
    public let deviceName: String

    private let queue = DispatchQueue(label: "com.leapin.sync.server", qos: .userInitiated)
    private let lock = NSLock()

    private var listener: NWListener?
    private var boundPort: UInt16?
    private var running = false

    private var activeCode: String?
    private var codeIssuedAt = Date.distantPast
    private var nonces: [String: Date] = [:]

    public init(identity: DeviceIdentity, store: ProfileVersionStore, peers: PeerRegistry,
                port: UInt16 = 7901, bindLAN: Bool = true, deviceName: String,
                panelToken: String? = nil,
                panelTokenProvider: (@Sendable () -> String?)? = nil,
                appliedVersionProvider: (@Sendable () -> String?)? = nil) {
        self.identity = identity
        self.store = store
        self.peers = peers
        self.requestedPort = port
        self.bindLAN = bindLAN
        self.deviceName = deviceName
        if let panelTokenProvider {
            self.panelTokenProvider = panelTokenProvider
        } else if let panelToken {
            self.panelTokenProvider = { panelToken }
        } else {
            self.panelTokenProvider = nil
        }
        self.appliedVersionProvider = appliedVersionProvider
    }

    deinit { stop() }

    // MARK: Identity

    public var syncDevice: SyncDevice { SyncDevice(identity: identity, name: deviceName) }

    public var isRunning: Bool { lock.withLock { running } }

    public var listeningPort: UInt16? { lock.withLock { boundPort } }

    /// The code a UI should display. Expired codes are replaced on read so the
    /// caller never shows a dead code; an in-flight POST with an expired code
    /// still answers 410 because the handler checks the issue time itself.
    public var pairingCode: String {
        lock.withLock { currentCodeLocked(now: Date()) }
    }

    @discardableResult
    public func refreshPairingCode() -> String {
        lock.withLock {
            let fresh = PairingCode.make()
            activeCode = fresh
            codeIssuedAt = Date()
            return fresh
        }
    }

    private func currentCodeLocked(now: Date) -> String {
        if let activeCode, now.timeIntervalSince(codeIssuedAt) < Self.pairingCodeTTL {
            return activeCode
        }
        let fresh = PairingCode.make()
        activeCode = fresh
        codeIssuedAt = now
        return fresh
    }

    // MARK: Lifecycle

    @discardableResult
    public func start() throws -> UInt16 {
        if let boundPort, isRunning { return boundPort }
        let host: NWEndpoint.Host = bindLAN ? .ipv4(.any) : .ipv4(.loopback)
        var remaining = requestedPort == 0 ? 5 : 1
        var lastError: Error?

        while remaining > 0 {
            remaining -= 1
            let candidate: UInt16
            do {
                candidate = requestedPort != 0
                    ? requestedPort
                    : try Self.reserveEphemeralPort(allowLAN: bindLAN)
            } catch {
                lastError = error
                continue
            }
            guard let nwPort = NWEndpoint.Port(rawValue: candidate) else {
                throw SyncError.badRequest("invalid sync port \(candidate)")
            }

            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.connectionTimeout = 10
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: host, port: nwPort)

            let listener: NWListener
            do {
                listener = try NWListener(using: parameters)
            } catch {
                lastError = error
                continue
            }

            let gate = SyncStartGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.succeed()
                case .failed(let error): gate.fail(error)
                case .cancelled: gate.fail(SyncError.transport("sync listener cancelled during start"))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)

            switch gate.wait(timeout: 5) {
            case .ready:
                let actual = listener.port?.rawValue ?? candidate
                lock.withLock {
                    self.listener = listener
                    self.boundPort = actual
                    self.running = true
                    _ = currentCodeLocked(now: Date())
                }
                LPLog.shared.info("sync", "listening on \(bindLAN ? "0.0.0.0" : "127.0.0.1"):\(actual)")
                return actual
            case .failure(let error):
                listener.cancel()
                lastError = error
            case .timeout:
                listener.cancel()
                lastError = SyncError.transport("sync listener on port \(candidate) did not become ready")
            }
            if requestedPort != 0 { break }
        }

        throw SyncError.transport(
            "sync server could not bind \(bindLAN ? "0.0.0.0" : "127.0.0.1"):\(requestedPort): "
            + (lastError.map { "\($0)" } ?? "unknown error"))
    }

    public func stop() {
        let toCancel: NWListener? = lock.withLock {
            let current = listener
            listener = nil
            boundPort = nil
            running = false
            return current
        }
        toCancel?.cancel()
    }

    /// Network.framework refuses a requiredLocalEndpoint with port 0 (EINVAL),
    /// so an ephemeral port is reserved with BSD first and then rebound.
    private static func reserveEphemeralPort(allowLAN: Bool) throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SyncError.transport("socket() failed: errno \(errno)") }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = allowLAN ? INADDR_ANY : inet_addr("127.0.0.1")

        let bound: Int32 = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw SyncError.transport("bind probe failed: errno \(errno)") }

        var out = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named: Int32 = withUnsafeMutablePointer(to: &out) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &length)
            }
        }
        guard named == 0 else { throw SyncError.transport("getsockname failed: errno \(errno)") }
        let port = UInt16(bigEndian: out.sin_port)
        guard port != 0 else { throw SyncError.transport("system returned port 0") }
        return port
    }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if error != nil { connection.cancel(); return }
            var accumulated = buffer
            if let data, !data.isEmpty { accumulated.append(data) }

            switch self.parse(accumulated) {
            case .request(let request):
                self.handle(request, on: connection)
            case .invalid:
                self.sendError(status: 400, code: "bad_request", on: connection)
            case .tooLarge:
                self.sendError(status: 413, code: "payload_too_large", on: connection)
            case .incomplete:
                if isComplete {
                    if accumulated.isEmpty {
                        connection.cancel()
                    } else {
                        self.sendError(status: 400, code: "bad_request", on: connection)
                    }
                } else {
                    self.receive(on: connection, buffer: accumulated)
                }
            }
        }
    }

    // MARK: Routing

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        do {
            switch (request.method, request.path) {
            case ("GET", "/v1/info"):
                try sendJSON(syncDevice, on: connection)

            case ("GET", "/panel"):
                try handlePanel(request, asJSON: false, on: connection)

            case ("GET", "/panel.json"):
                try handlePanel(request, asJSON: true, on: connection)

            case ("POST", "/panel"), ("POST", "/panel.json"),
                 ("PUT", "/panel"), ("PUT", "/panel.json"),
                 ("DELETE", "/panel"), ("DELETE", "/panel.json"),
                 ("PATCH", "/panel"), ("PATCH", "/panel.json"):
                // The panel is read-only by construction; refuse every mutation
                // even with a valid token.
                sendError(status: 405, code: "method_not_allowed", on: connection)

            case ("POST", "/v1/pair"):
                try handlePair(request, on: connection)

            case ("GET", "/v1/manifest"):
                _ = try authenticate(request)
                let manifest = SyncManifest(device: syncDevice,
                                            versions: store.list(),
                                            pointers: store.pointers(),
                                            generatedAtMs: Self.nowMs())
                try sendJSON(manifest, on: connection)

            case ("GET", let path) where path.hasPrefix("/v1/versions/"):
                _ = try authenticate(request)
                let raw = String(path.dropFirst("/v1/versions/".count))
                guard let id = Self.versionID(from: raw) else {
                    throw SyncError.badRequest("invalid version id")
                }
                guard let data = try? store.data(id: id) else {
                    throw SyncError.http(404)
                }
                send(status: 200, body: data, on: connection)

            case ("POST", "/v1/announce"):
                let deviceID = try authenticate(request)
                try handleAnnounce(request, authenticatedDevice: deviceID, on: connection)

            default:
                if Self.knownPaths.contains(request.path) {
                    sendError(status: 405, code: "method_not_allowed", on: connection)
                } else {
                    sendError(status: 404, code: "not_found", on: connection)
                }
            }
        } catch let error as SyncError {
            respond(error: error, on: connection)
        } catch let error as VersionStoreError {
            switch error {
            case .unknownVersion: sendError(status: 404, code: "not_found", on: connection)
            default: sendError(status: 400, code: "bad_request", on: connection)
            }
        } catch {
            LPLog.shared.error("sync", "route failed: \(error)")
            sendError(status: 500, code: "internal_error", on: connection)
        }
    }

    private static let knownPaths: Set<String> = ["/v1/info", "/v1/pair", "/v1/manifest", "/v1/announce",
                                                  "/v1/versions", "/panel", "/panel.json"]

    private static func versionID(from raw: String) -> String? {
        let decoded = raw.removingPercentEncoding ?? raw
        guard decoded.count == 64, decoded.allSatisfy({ $0.isHexDigit }) else { return nil }
        return decoded.lowercased()
    }

    // MARK: Pairing

    private func handlePair(_ request: HTTPRequest, on connection: NWConnection) throws {
        let pair: PairRequest
        do {
            pair = try JSONDecoder.sync.decode(PairRequest.self, from: request.body)
        } catch {
            throw SyncError.badRequest("invalid pair body")
        }
        guard pair.device.publicKeyData?.count == 32 else {
            throw SyncError.badRequest("invalid device public key")
        }

        let now = Date()
        let presented = PairingCode.normalize(pair.code)
        let state: (active: String?, expired: Bool) = lock.withLock {
            guard let activeCode else { return (nil, false) }
            if now.timeIntervalSince(codeIssuedAt) >= Self.pairingCodeTTL {
                self.activeCode = nil
                return (activeCode, true)
            }
            return (activeCode, false)
        }
        if state.expired { throw SyncError.pairingExpired }
        guard let active = state.active, presented.count == 6,
              Self.constantTimeEquals(presented, active) else {
            throw SyncError.badPairingCode
        }

        // Single use: consume before touching the registry so a racing duplicate
        // cannot ride the same code.
        lock.withLock { activeCode = nil }
        let peer = peers.upsert(pair.device, at: now)
        LPLog.shared.info("sync", "paired \(peer.device.name) (\(peer.device.deviceID))")
        try sendJSON(PairResponse(ok: true, device: syncDevice), on: connection)
    }

    // MARK: Read-only panel

    private func handlePanel(_ request: HTTPRequest, asJSON: Bool,
                             on connection: NWConnection) throws {
        guard let panelToken = panelTokenProvider?(), !panelToken.isEmpty else {
            sendError(status: 404, code: "not_found", on: connection)
            return
        }
        let bearer = request.header("authorization").flatMap { value -> String? in
            guard value.hasPrefix("Bearer ") else { return nil }
            return String(value.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
        }
        let provided = bearer ?? request.query["token"] ?? ""
        guard Self.constantTimeEquals(provided, panelToken) else {
            throw SyncError.unauthorized("panel token mismatch")
        }
        let snapshot = SyncPanelSnapshot(
            device: syncDevice,
            generatedAtMs: Self.nowMs(),
            versions: store.list(),
            pointers: store.pointers(),
            effective: store.effectiveActiveVersion(),
            applied: appliedVersionProvider.flatMap { $0() },
            peers: peers.all())
        if asJSON {
            try sendJSON(snapshot, on: connection)
        } else {
            send(status: 200, body: Data(SyncPanelHTML.render(snapshot).utf8),
                 contentType: "text/html; charset=utf-8", on: connection)
        }
    }

    // MARK: Announce

    private func handleAnnounce(_ request: HTTPRequest, authenticatedDevice: String,
                                on connection: NWConnection) throws {
        let envelope: SyncAnnounceEnvelope
        do {
            envelope = try JSONDecoder.sync.decode(SyncAnnounceEnvelope.self, from: request.body)
        } catch {
            throw SyncError.badRequest("invalid announce body")
        }
        guard envelope.device.deviceID == authenticatedDevice else {
            throw SyncError.unauthorized("announced device does not match signer")
        }

        // Pointers first: an advertised version we already hold is applied now,
        // and the second merge below picks up the ones the payload completed.
        _ = store.merge(pointers: envelope.pointers)

        for version in envelope.versions {
            var content: Data? = nil
            if let encoded = envelope.contents?[version.id], let decoded = Data(base64Encoded: encoded) {
                content = decoded
            } else if let local = try? store.data(id: version.id) {
                content = local
            }
            guard let content else { continue }
            // ingest re-hashes the payload against the advertised id and
            // throws on mismatch; a bad version never becomes visible.
            _ = try? store.ingest(content: content, meta: version)
        }

        _ = store.merge(pointers: envelope.pointers)
        let need = store.missing(from: envelope.versions).map(\.id)
        let response = AnnounceResponse(accepted: true, needVersions: need, pointers: store.pointers())
        try sendJSON(response, on: connection)
    }

    // MARK: Auth

    private func authenticate(_ request: HTTPRequest) throws -> String {
        guard let deviceID = request.header(SyncAuth.headerDevice), !deviceID.isEmpty else {
            throw SyncError.unauthorized("missing device header")
        }
        // Replay is decided before the signature: a captured envelope must not
        // be re-verifiable at all, even if verification would later fail.
        if let nonce = request.header(SyncAuth.headerNonce), !nonce.isEmpty {
            let seen: Bool = lock.withLock {
                pruneNoncesLocked(now: Date())
                if nonces[nonce] != nil { return true }
                nonces[nonce] = Date()
                if nonces.count > Self.nonceLimit {
                    let overflow = nonces.count - Self.nonceLimit
                    for key in nonces.sorted(by: { $0.value < $1.value }).prefix(overflow).map(\.key) {
                        nonces.removeValue(forKey: key)
                    }
                }
                return false
            }
            if seen { throw SyncError.replay }
        }
        guard let peer = peers.peer(deviceID: deviceID), let key = peer.device.publicKeyData else {
            throw SyncError.unauthorized("unknown peer \(deviceID)")
        }
        let signed = [
            SyncAuth.headerDevice: deviceID,
            SyncAuth.headerTimestamp: request.header(SyncAuth.headerTimestamp) ?? "",
            SyncAuth.headerNonce: request.header(SyncAuth.headerNonce) ?? "",
            SyncAuth.headerSignature: request.header(SyncAuth.headerSignature) ?? "",
        ]
        try SyncAuth.verify(headers: signed, method: request.method, path: request.path,
                            body: request.body, peerPublicKey: key)
        peers.touch(deviceID: deviceID)
        return deviceID
    }

    private func pruneNoncesLocked(now: Date) {
        guard !nonces.isEmpty else { return }
        let cutoff = now.addingTimeInterval(-Self.nonceTTL)
        nonces = nonces.filter { $0.value >= cutoff }
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference: UInt8 = a.count == b.count ? 0 : 1
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            difference |= x ^ y
        }
        return difference == 0
    }

    // MARK: HTTP parsing

    private struct HTTPRequest {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    private struct ParsedHead {
        var method: String
        var target: String
        var headers: [String: String]
    }

    private enum ParseOutcome {
        case incomplete
        case invalid
        case tooLarge
        case request(HTTPRequest)
    }

    private static let headerSeparator = Data("\r\n\r\n".utf8)

    private func parse(_ buffer: Data) -> ParseOutcome {
        guard let headerEnd = buffer.range(of: Self.headerSeparator) else {
            return buffer.count > Self.maxHeaderBytes ? .tooLarge : .incomplete
        }
        guard headerEnd.lowerBound <= Self.maxHeaderBytes,
              let head = Self.parseHead(buffer[..<headerEnd.lowerBound]) else { return .invalid }
        if head.headers["transfer-encoding"] != nil { return .invalid }

        var contentLength = 0
        if let raw = head.headers["content-length"] {
            guard let value = Int(raw), value >= 0 else { return .invalid }
            contentLength = value
        }
        if contentLength > Self.maxBodyBytes { return .tooLarge }

        let bodyStart = headerEnd.upperBound
        let available = buffer.count - bodyStart
        guard available >= contentLength else { return .incomplete }

        var body = Data()
        if contentLength > 0 { body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength)) }
        let (path, query) = Self.splitTarget(head.target)
        return .request(HTTPRequest(method: head.method, path: path, query: query,
                                    headers: head.headers, body: body))
    }

    private static func parseHead(_ data: Data) -> ParsedHead? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        return ParsedHead(method: String(parts[0]).uppercased(),
                          target: String(parts[1]), headers: headers)
    }

    private static func splitTarget(_ target: String) -> (String, [String: String]) {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pieces[0])
        var query: [String: String] = [:]
        if pieces.count == 2 {
            for pair in pieces[1].split(separator: "&") where !pair.isEmpty {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let rawKey = kv.first else { continue }
                let key = String(rawKey).removingPercentEncoding ?? String(rawKey)
                let rawValue = kv.count == 2 ? String(kv[1]) : ""
                let value = rawValue.removingPercentEncoding ?? rawValue
                if !key.isEmpty { query[key] = value }
            }
        }
        return (path, query)
    }

    // MARK: Responses

    private func sendJSON<T: Encodable>(_ value: T, status: Int = 200,
                                        on connection: NWConnection) throws {
        let body = try JSONEncoder.sync.encode(value)
        send(status: status, body: body, on: connection)
    }

    private func send(status: Int, body: Data,
                      contentType: String = "application/json",
                      on connection: NWConnection) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendError(status: Int, code: String, on connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": code], options: [.sortedKeys]))
            ?? Data("{\"error\":\"internal_error\"}".utf8)
        send(status: status, body: body, on: connection)
    }

    private func respond(error: SyncError, on connection: NWConnection) {
        switch error {
        case .badPairingCode: sendError(status: 400, code: "bad_pairing_code", on: connection)
        case .pairingExpired: sendError(status: 410, code: "pairing_expired", on: connection)
        case .unauthorized: sendError(status: 401, code: "unauthorized", on: connection)
        case .notPaired: sendError(status: 401, code: "not_paired", on: connection)
        case .replay: sendError(status: 409, code: "replay", on: connection)
        case .staleTimestamp: sendError(status: 401, code: "stale_timestamp", on: connection)
        case .badRequest: sendError(status: 400, code: "bad_request", on: connection)
        case .malformedResponse: sendError(status: 400, code: "bad_request", on: connection)
        case .http(let code): sendError(status: code, code: "peer_error_\(code)", on: connection)
        case .transport: sendError(status: 500, code: "internal_error", on: connection)
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 413: return "Content Too Large"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

// MARK: - Start gate

private final class SyncStartGate: @unchecked Sendable {
    enum Outcome {
        case ready
        case failure(Error)
        case timeout
    }

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outcome: Outcome?
    private var claimed = false

    func succeed() { finish(.ready) }

    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ value: Outcome) {
        let signal = lock.withLock { () -> Bool in
            guard outcome == nil else { return false }
            outcome = value
            return true
        }
        if signal { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) -> Outcome {
        _ = semaphore.wait(timeout: .now() + timeout)
        return lock.withLock { outcome ?? .timeout }
    }
}