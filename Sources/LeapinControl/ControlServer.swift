import Foundation
import Network
import LeapinCore
import Darwin

// MARK: - Control server
//
// A tiny, dependency-free HTTP/1.1 action surface bound to loopback. It owns
// transport, auth, audit and the SSE event stream; every mutation is delegated to
// the engine through ControlBackend on the main actor.

public final class ControlServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var port: UInt16
        public var allowLAN: Bool
        public var tokenFile: URL
        public var auditFile: URL
        public var maxReplayEvents: Int

        public init(port: UInt16 = 7900, allowLAN: Bool = false, tokenFile: URL, auditFile: URL,
                    maxReplayEvents: Int = 500) {
            self.port = port
            self.allowLAN = allowLAN
            self.tokenFile = tokenFile
            self.auditFile = auditFile
            self.maxReplayEvents = maxReplayEvents
        }
    }

    public let configuration: Configuration
    /// Bearer token loaded from (or generated into) configuration.tokenFile.
    public let token: String

    private weak var backend: (any ControlBackend)?
    private let lock = NSLock()
    private let auditQueue = DispatchQueue(label: "com.leapin.control.audit")
    private let queue = DispatchQueue(label: "com.leapin.control.server", qos: .userInitiated)

    private let maxBodyBytes = 1 << 20
    private let maxHeaderBytes = 64 << 10
    private let auditRotationBytes = 5 * 1024 * 1024

    private var listener: NWListener?
    private var boundPort: Int?
    private var running = false
    private var replay: [ControlEvent] = []
    private var lastSeq = 0
    private var sseClients: [UUID: SSEClient] = [:]

    // MARK: Lifecycle

    public init(configuration: Configuration, backend: ControlBackend?) throws {
        self.configuration = configuration
        self.backend = backend

        let fileManager = FileManager.default
        let tokenDirectory = configuration.tokenFile.deletingLastPathComponent()
        let auditDirectory = configuration.auditFile.deletingLastPathComponent()
        for directory in [tokenDirectory, auditDirectory] where directory.path != "/" {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        if let existing = try? String(contentsOf: configuration.tokenFile, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isValidToken(trimmed) {
                self.token = trimmed
            } else {
                let generated = Self.generateToken()
                try Self.writeToken(generated, to: configuration.tokenFile)
                self.token = generated
            }
        } else {
            let generated = Self.generateToken()
            try Self.writeToken(generated, to: configuration.tokenFile)
            self.token = generated
        }

        if !fileManager.fileExists(atPath: configuration.auditFile.path) {
            fileManager.createFile(atPath: configuration.auditFile.path, contents: nil,
                                   attributes: [.posixPermissions: 0o600])
        }
    }

    deinit {
        stop()
    }

    public var isRunning: Bool { lock.withLock { running } }

    public var listeningPort: Int? { lock.withLock { boundPort } }

    public func start() throws {
        if isRunning { return }
        guard let nwPort = NWEndpoint.Port(rawValue: configuration.port) else {
            throw ControlError.badRequest("invalid control port \(configuration.port)")
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: configuration.allowLAN ? .ipv4(.any) : .ipv4(.loopback),
            port: nwPort)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ControlError.unavailable(
                "cannot create control listener on port \(configuration.port): \(error.localizedDescription)")
        }

        let gate = ControlStartGate()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                gate.succeed()
            case .failed(let error):
                gate.fail(error)
            case .cancelled:
                gate.fail(ControlError.unavailable("control listener cancelled during start"))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        switch gate.wait(timeout: 5) {
        case .ready:
            break
        case .failure(let error):
            listener.cancel()
            throw ControlError.unavailable(
                "control listener on port \(configuration.port) failed: \(error.localizedDescription)")
        case .timeout:
            listener.cancel()
            throw ControlError.unavailable(
                "control listener on port \(configuration.port) did not become ready in time")
        }

        let actualPort = listener.port.map { Int($0.rawValue) } ?? Int(configuration.port)
        lock.withLock {
            self.listener = listener
            self.boundPort = actualPort
            self.running = true
        }
        LPLog.shared.info("control",
            "listening on \(configuration.allowLAN ? "0.0.0.0" : "127.0.0.1"):\(actualPort)")
    }

    public func stop() {
        let snapshot: (NWListener?, [SSEClient]) = lock.withLock {
            let listener = self.listener
            let clients = Array(self.sseClients.values)
            self.listener = nil
            self.boundPort = nil
            self.running = false
            self.sseClients.removeAll()
            self.replay.removeAll()
            return (listener, clients)
        }
        snapshot.0?.cancel()
        for client in snapshot.1 { client.close() }
    }

    // MARK: Events (SSE)

    /// Thread-safe fan-out used by the engine sink. Non-positive seq values are
    /// assigned by the server so callers cannot accidentally rewind the stream.
    public func publish(_ event: ControlEvent) {
        var event = event
        let clients: [SSEClient] = lock.withLock {
            if event.seq <= 0 {
                lastSeq += 1
                event.seq = lastSeq
            } else if event.seq > lastSeq {
                lastSeq = event.seq
            }
            replay.append(event)
            if configuration.maxReplayEvents <= 0 {
                replay.removeAll()
            } else if replay.count > configuration.maxReplayEvents {
                replay.removeFirst(replay.count - configuration.maxReplayEvents)
            }
            return Array(sseClients.values)
        }
        guard let frame = Self.sseFrame(event) else { return }
        for client in clients { client.send(frame) }
    }

    private func startSSE(since: Int, on connection: NWConnection) {
        let client = SSEClient(connection: connection)
        connection.stateUpdateHandler = { [weak self, weak client] state in
            switch state {
            case .failed, .cancelled:
                if let id = client?.id { self?.removeSSEClient(id) }
            default:
                break
            }
        }
        client.onClose = { [weak self, weak client] in
            if let id = client?.id { self?.removeSSEClient(id) }
        }

        // SSE clients never send another byte, so an idle receive() is the only
        // reliable way to learn that the peer closed: NWConnection reports
        // remote FIN as isComplete (and RST as an error). Without this probe a
        // disconnected consumer would linger until the next heartbeat fails.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self, weak client] _, _, isComplete, error in
            if isComplete || error != nil {
                if let id = client?.id { self?.removeSSEClient(id) }
            }
        }

        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: text/event-stream; charset=utf-8\r\n"
        header += "Cache-Control: no-cache, no-transform\r\n"
        header += "Connection: keep-alive\r\n"
        header += "X-Accel-Buffering: no\r\n"
        header += "\r\n"

        lock.withLock {
            sseClients[client.id] = client
            let frames = replay.filter { $0.seq > since }.compactMap { Self.sseFrame($0) }
            // Enqueue header + replay while still holding the lock so any
            // concurrent publish() always enqueues after the replay frames.
            client.start(header: Data(header.utf8), replay: frames)
        }
    }

    /// Number of attached SSE consumers. Internal so tests can wait for the
    /// subscription to register instead of racing a publish.
    var sseClientCount: Int { lock.withLock { sseClients.count } }

    private func removeSSEClient(_ id: UUID) {
        let client = lock.withLock { sseClients.removeValue(forKey: id) }
        client?.close()
    }

    private static func sseFrame(_ event: ControlEvent) -> Data? {
        guard let json = try? JSONEncoder().encode(event),
              let text = String(data: json, encoding: .utf8) else { return nil }
        return Data("id: \(event.seq)\nevent: flow\ndata: \(text)\n\n".utf8)
    }

    // MARK: Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if error != nil {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data, !data.isEmpty { accumulated.append(data) }

            switch self.parse(accumulated) {
            case .request(let request):
                self.dispatch(request, on: connection)
            case .invalid:
                self.sendFailure(status: 400, code: "bad_request",
                                 message: "malformed HTTP request", to: connection)
            case .tooLarge:
                self.sendFailure(status: 413, code: "payload_too_large",
                                 message: "request too large", to: connection)
            case .incomplete:
                if isComplete {
                    if accumulated.isEmpty {
                        connection.cancel()
                    } else {
                        self.sendFailure(status: 400, code: "bad_request",
                                         message: "incomplete HTTP request", to: connection)
                    }
                } else {
                    self.receive(on: connection, buffer: accumulated)
                }
            }
        }
    }

    private func dispatch(_ request: HTTPRequest, on connection: NWConnection) {
        Task { [weak self] in
            guard let self else { connection.cancel(); return }
            await self.route(request, on: connection)
        }
    }

    // MARK: Routing

    private func route(_ request: HTTPRequest, on connection: NWConnection) async {
        let remote = Self.remoteDescription(connection)
        let action = Self.actionName(method: request.method, path: request.path)
        let presented = presentedToken(request)

        guard let presented, Self.constantTimeEquals(presented, token) else {
            let prefix = presented.map { String($0.prefix(8)) } ?? ""
            audit(method: request.method, path: request.path, action: action, status: 401,
                  remote: remote, allowed: false, tokenPrefix: prefix,
                  detail: presented == nil ? "missing token" : "invalid token")
            sendFailure(status: 401, code: "unauthorized",
                        message: "missing or invalid control token", to: connection)
            return
        }

        let tokenPrefix = String(token.prefix(8))
        func finish(_ status: Int, _ detail: String) {
            audit(method: request.method, path: request.path, action: action, status: status,
                  remote: remote, allowed: true, tokenPrefix: tokenPrefix, detail: detail)
        }

        do {
            switch (request.method, request.path) {
            case ("GET", "/v1/status"):
                let status = try await callBackend { await $0.controlStatus() }
                finish(200, "engine=\(status.engineState) rules=\(status.ruleCount)")
                sendOK(status, to: connection)

            case ("GET", "/v1/connections"):
                let limit = queryLimit(request, defaultValue: 50, maximum: 1000)
                let connections = try await callBackend { await $0.controlConnections(limit: limit) }
                finish(200, "limit=\(limit) count=\(connections.count)")
                let items = connections.compactMap { Self.jsonObject($0) }
                sendObject(["ok": true, "count": items.count, "connections": items], to: connection)

            case ("GET", "/v1/policies"):
                let policies = try await callBackend { await $0.controlPolicies() }
                finish(200, "count=\(policies.count)")
                let items = policies.compactMap { Self.jsonObject($0) }
                sendObject(["ok": true, "count": items.count, "policies": items], to: connection)

            case ("POST", "/v1/policies/select"):
                let body = try decodeBody(SelectBody.self, from: request)
                let group = body.group.trimmingCharacters(in: .whitespacesAndNewlines)
                let outbound = body.outbound.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !group.isEmpty, !outbound.isEmpty else {
                    throw ControlError.badRequest("group and outbound are required")
                }
                let result = try await callBackend {
                    try await $0.controlSelect(group: group, outbound: outbound)
                }
                finish(200, "group=\(result.group) outbound=\(result.outbound) persisted=\(result.persisted)")
                sendOK(result, to: connection)

            case ("POST", "/v1/reload"):
                let result = try await callBackend { try await $0.controlReload() }
                finish(200, "restarted=\(result.restarted) applied=\(result.applied.joined(separator: ","))")
                sendOK(result, to: connection)

            case ("POST", "/v1/explain"):
                let body = try decodeBody(ExplainBody.self, from: request)
                let host = body.host.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty else { throw ControlError.badRequest("host is required") }
                let port = body.port ?? 443
                guard (1...65535).contains(port) else {
                    throw ControlError.badRequest("port must be between 1 and 65535")
                }
                let result = try await callBackend {
                    try await $0.controlExplain(host: host, port: port)
                }
                finish(200, "host=\(result.host) policy=\(result.policy) outbound=\(result.outbound)")
                sendOK(result, to: connection)

            case ("POST", "/v1/dns/trace"):
                let body = try decodeBody(TraceBody.self, from: request)
                let host = body.host.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty else { throw ControlError.badRequest("host is required") }
                let trace = try await callBackend { try await $0.controlDNSTrace(host: host) }
                finish(200, "host=\(trace.host) source=\(trace.source.rawValue) resolved=\(trace.resolved.count)")
                sendObject(["ok": true, "trace": Self.jsonObject(trace) ?? [:]], to: connection)

            case ("POST", "/v1/http/probe"):
                let body = try decodeBody(ProbeBody.self, from: request)
                let url = body.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { throw ControlError.badRequest("url is required") }
                let timeoutMs = max(1000, min(body.timeoutMs ?? 10_000, 30_000))
                let probe = try await callBackend(timeout: 30) {
                    try await $0.controlHTTPProbe(url: url, timeoutMs: timeoutMs)
                }
                finish(200, "url=\(probe.url) status=\(probe.statusCode ?? 0)")
                sendObject(["ok": true, "probe": Self.jsonObject(probe) ?? [:]], to: connection)

            case ("GET", "/v1/audit"):
                let limit = queryLimit(request, defaultValue: 100, maximum: 1000)
                let records = loadAudit(limit: limit)
                finish(200, "limit=\(limit) count=\(records.count)")
                let items = records.compactMap { Self.jsonObject($0) }
                sendObject(["ok": true, "count": items.count, "records": items], to: connection)

            case ("GET", "/v1/events"):
                let since = max(0, Int(request.query["since"] ?? "") ?? 0)
                startSSE(since: since, on: connection)
                finish(200, "sse since=\(since)")
                return

            default:
                if let allowed = Self.allowedMethods[request.path] {
                    finish(405, "method \(request.method) not allowed")
                    sendFailure(status: 405, code: "method_not_allowed",
                                message: "method \(request.method) is not allowed for \(request.path)",
                                to: connection, headers: ["Allow": allowed.joined(separator: ", ")])
                } else {
                    finish(404, "unknown path")
                    sendFailure(status: 404, code: "not_found",
                                message: "unknown control path \(request.path)", to: connection)
                }
            }
        } catch let error as ControlError {
            finish(error.statusCode, error.errorDescription ?? error.code)
            sendFailure(status: error.statusCode, code: error.code,
                        message: error.errorDescription ?? error.code, to: connection)
        } catch {
            finish(500, error.localizedDescription)
            sendFailure(status: 500, code: "internal_error",
                        message: error.localizedDescription, to: connection)
        }
    }

    // MARK: Backend calls

    /// Runs a backend call on the main actor with a hard timeout so a wedged
    /// engine can never pin a control connection forever.
    private func callBackend<T: Sendable>(
        timeout: TimeInterval = 10,
        _ operation: @escaping @MainActor @Sendable (any ControlBackend) async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self, let backend = self.backend else {
                    throw ControlError.unavailable("control backend is not attached")
                }
                return try await operation(backend)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1_000_000_000))
                throw ControlError.unavailable("backend timed out after \(Int(timeout))s")
            }
            guard let first = try await group.next() else {
                group.cancelAll()
                throw ControlError.unavailable("backend returned no result")
            }
            group.cancelAll()
            return first
        }
    }

    // MARK: HTTP parsing

    private struct HTTPRequest {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data
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

    private struct SelectBody: Decodable { var group: String; var outbound: String }
    private struct ExplainBody: Decodable { var host: String; var port: Int? }
    private struct TraceBody: Decodable { var host: String }
    private struct ProbeBody: Decodable { var url: String; var timeoutMs: Int? }

    private static let headerSeparator = Data("\r\n\r\n".utf8)

    private func parse(_ buffer: Data) -> ParseOutcome {
        guard let headerEnd = buffer.range(of: Self.headerSeparator) else {
            return buffer.count > maxHeaderBytes ? .tooLarge : .incomplete
        }
        guard let head = Self.parseHead(buffer[..<headerEnd.lowerBound]) else { return .invalid }
        if head.headers["transfer-encoding"] != nil { return .invalid }

        var contentLength = 0
        if let raw = head.headers["content-length"] {
            guard let value = Int(raw), value >= 0 else { return .invalid }
            contentLength = value
        }
        if contentLength > maxBodyBytes { return .tooLarge }

        let bodyStart = headerEnd.upperBound
        let available = buffer.count - bodyStart
        guard available >= contentLength else { return .incomplete }

        var body = Data()
        if contentLength > 0 {
            body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        }
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

    // MARK: Auth

    private func presentedToken(_ request: HTTPRequest) -> String? {
        if let raw = request.headers["authorization"] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("bearer ") {
                let value = String(trimmed.dropFirst("bearer ".count))
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            } else if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let value = request.headers["x-leapin-token"], !value.isEmpty { return value }
        if let value = request.query["token"], !value.isEmpty { return value }
        return nil
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference: UInt8 = a.count == b.count ? 0 : 1
        let count = max(a.count, b.count)
        for index in 0..<count {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            difference |= x ^ y
        }
        return difference == 0
    }

    // MARK: Tokens

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidToken(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    private static func writeToken(_ token: String, to url: URL) throws {
        guard let data = token.data(using: .utf8) else {
            throw ControlError.unavailable("cannot encode control token")
        }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".control-token-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ControlError.unavailable("cannot create control token file")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: temp.path)
        let result: Int32 = temp.withUnsafeFileSystemRepresentation { from -> Int32 in
            url.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { return -1 }
                return rename(from, to)
            }
        }
        if result != 0 {
            try? FileManager.default.removeItem(at: temp)
            throw ControlError.unavailable("cannot install control token file: errno \(errno)")
        }
    }

    // MARK: Audit

    private func audit(method: String, path: String, action: String, status: Int, remote: String,
                       allowed: Bool, tokenPrefix: String, detail: String) {
        let record = ControlAuditRecord(
            timestampMs: Date().timeIntervalSince1970 * 1000,
            method: method, path: path, action: action, status: status,
            remote: remote, allowed: allowed, tokenPrefix: tokenPrefix, detail: detail)
        guard var line = try? JSONEncoder().encode(record) else { return }
        line.append(0x0A)
        auditQueue.sync {
            rotateAuditIfNeeded()
            ensureAuditFile()
            guard let handle = FileHandle(forWritingAtPath: configuration.auditFile.path) else { return }
            defer { _ = try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    private func ensureAuditFile() {
        if !FileManager.default.fileExists(atPath: configuration.auditFile.path) {
            FileManager.default.createFile(atPath: configuration.auditFile.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    private func rotateAuditIfNeeded() {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: configuration.auditFile.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > auditRotationBytes else { return }
        let rotated = configuration.auditFile.appendingPathExtension("1")
        try? fileManager.removeItem(at: rotated)
        try? fileManager.moveItem(at: configuration.auditFile, to: rotated)
    }

    private func loadAudit(limit: Int) -> [ControlAuditRecord] {
        auditQueue.sync {
            guard let data = try? Data(contentsOf: configuration.auditFile), !data.isEmpty else {
                return []
            }
            let decoder = JSONDecoder()
            var records: [ControlAuditRecord] = []
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let record = try? decoder.decode(ControlAuditRecord.self, from: Data(line)) {
                    records.append(record)
                }
            }
            return Array(records.suffix(limit))
        }
    }

    // MARK: Response helpers

    private func sendOK<T: Encodable>(_ value: T, extra: [String: Any] = [:], to connection: NWConnection) {
        var object = Self.jsonObject(value) as? [String: Any] ?? [:]
        object["ok"] = true
        for (key, value) in extra { object[key] = value }
        sendObject(object, to: connection)
    }

    private func sendObject(_ object: [String: Any], to connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: object))
            ?? Data("{\"ok\":false,\"error\":\"internal_error\",\"message\":\"response encoding failed\"}".utf8)
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendFailure(status: Int, code: String, message: String, to connection: NWConnection,
                             headers: [String: String] = [:]) {
        let body = (try? JSONSerialization.data(withJSONObject: [
            "ok": false, "error": code, "message": message
        ])) ?? Data()
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Connection: close\r\n"
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }

    private func queryLimit(_ request: HTTPRequest, defaultValue: Int, maximum: Int) -> Int {
        guard let raw = request.query["limit"], let value = Int(raw) else { return defaultValue }
        return max(1, min(value, maximum))
    }

    private func decodeBody<T: Decodable>(_ type: T.Type, from request: HTTPRequest) throws -> T {
        guard !request.body.isEmpty else {
            throw ControlError.badRequest("request body is required")
        }
        do {
            return try JSONDecoder().decode(T.self, from: request.body)
        } catch {
            throw ControlError.badRequest("invalid JSON body: \(error.localizedDescription)")
        }
    }

    private static func remoteDescription(_ connection: NWConnection) -> String {
        if case let .hostPort(host, port) = connection.endpoint {
            return "\(host):\(port)"
        }
        return String(describing: connection.endpoint)
    }

    private static func actionName(method: String, path: String) -> String {
        switch path {
        case "/v1/status": return "status"
        case "/v1/connections": return "connections"
        case "/v1/policies": return "policies"
        case "/v1/policies/select": return "policies.select"
        case "/v1/reload": return "reload"
        case "/v1/explain": return "explain"
        case "/v1/dns/trace": return "dns.trace"
        case "/v1/http/probe": return "http.probe"
        case "/v1/audit": return "audit"
        case "/v1/events": return "events"
        default: return "unknown"
        }
    }

    private static let allowedMethods: [String: [String]] = [
        "/v1/status": ["GET"],
        "/v1/connections": ["GET"],
        "/v1/policies": ["GET"],
        "/v1/policies/select": ["POST"],
        "/v1/reload": ["POST"],
        "/v1/explain": ["POST"],
        "/v1/dns/trace": ["POST"],
        "/v1/http/probe": ["POST"],
        "/v1/audit": ["GET"],
        "/v1/events": ["GET"]
    ]
}

// MARK: - SSE client

private final class SSEClient: @unchecked Sendable {
    let id = UUID()
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var closed = false
    private var timer: DispatchSourceTimer?

    init(connection: NWConnection) {
        self.connection = connection
        self.queue = DispatchQueue(label: "com.leapin.control.sse.\(id.uuidString)")
    }

    func start(header: Data, replay: [Data]) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.connection.send(content: header, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.close() }
            })
            for frame in replay { self.sendOnQueue(frame) }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .seconds(15), repeating: .seconds(15))
            timer.setEventHandler { [weak self] in
                self?.sendOnQueue(Data(": ping\n\n".utf8))
            }
            self.lock.withLock { self.timer = timer }
            timer.resume()
        }
    }

    func send(_ frame: Data) {
        queue.async { [weak self] in self?.sendOnQueue(frame) }
    }

    private func sendOnQueue(_ frame: Data) {
        guard !isClosed else { return }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    private var isClosed: Bool { lock.withLock { closed } }

    func close() {
        let (alreadyClosed, timer): (Bool, DispatchSourceTimer?) = lock.withLock {
            if closed { return (true, nil) }
            closed = true
            let pending = self.timer
            self.timer = nil
            return (false, pending)
        }
        guard !alreadyClosed else { return }
        timer?.cancel()
        connection.cancel()
        onClose?()
    }
}

// MARK: - Start synchronisation

private final class ControlStartGate: @unchecked Sendable {
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