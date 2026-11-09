import Foundation
import TouchFlowNet
import TouchFlowCore

// MARK: - Sync client
//
// One-shot HTTP/1.1 over a fresh connection per request (Connection: close).
// Every request except /v1/info and /v1/pair carries the SyncAuth envelope,
// signed with the local device key over method + path + body hash + ts + nonce.

public final class SyncClient: @unchecked Sendable {
    public struct SyncReport: Sendable {
        public var pulled: [String]
        public var pointersChanged: [String]
        public var active: String?

        public init(pulled: [String] = [], pointersChanged: [String] = [], active: String? = nil) {
            self.pulled = pulled
            self.pointersChanged = pointersChanged
            self.active = active
        }
    }

    public static let maxResponseBytes = 8 << 20
    /// Content pushed back inside an announce must stay under the server's 4 MiB
    /// body cap; the slack leaves room for metadata and the signed envelope.
    static let maxPushBytes = 3 << 20

    public let identity: DeviceIdentity
    public let store: ProfileVersionStore
    public let peers: PeerRegistry
    public let host: String
    public let port: UInt16
    public let deviceName: String
    public let timeout: TimeInterval

    public init(identity: DeviceIdentity, store: ProfileVersionStore, peers: PeerRegistry,
                host: String, port: UInt16, deviceName: String? = nil,
                timeout: TimeInterval = 10) {
        self.identity = identity
        self.store = store
        self.peers = peers
        self.host = host
        self.port = port
        self.deviceName = deviceName ?? ProcessInfo.processInfo.hostName
        self.timeout = timeout
    }

    public var syncDevice: SyncDevice { SyncDevice(identity: identity, name: deviceName) }

    // MARK: Wire calls

    public func info() async throws -> SyncDevice {
        let reply = try await send(method: "GET", path: "/v1/info", signed: false)
        return try decode(SyncDevice.self, from: reply)
    }

    /// Exchanges the short-lived code for a pinned peer record. A 400 means the
    /// code was wrong (or already consumed), a 410 means it expired.
    @discardableResult
    public func pair(code: String) async throws -> SyncDevice {
        let request = PairRequest(code: PairingCode.normalize(code), device: syncDevice)
        let body = try JSONEncoder.sync.encode(request)
        do {
            let reply = try await send(method: "POST", path: "/v1/pair", body: body, signed: false)
            let response = try decode(PairResponse.self, from: reply)
            guard response.ok else { throw SyncError.badPairingCode }
            peers.upsert(response.device, at: Date())
            TFLog.shared.info("sync", "paired with \(response.device.name) (\(response.device.deviceID))")
            return response.device
        } catch SyncError.http(let code) where code == 400 {
            throw SyncError.badPairingCode
        } catch SyncError.http(let code) where code == 410 {
            throw SyncError.pairingExpired
        }
    }

    public func fetchManifest() async throws -> SyncManifest {
        let reply = try await send(method: "GET", path: "/v1/manifest")
        return try decode(SyncManifest.self, from: reply)
    }

    public func fetchVersion(id: String) async throws -> Data {
        guard Self.isVersionID(id) else { throw SyncError.badRequest("invalid version id \(id)") }
        let reply = try await send(method: "GET", path: "/v1/versions/\(id)")
        return reply.body
    }

    public func announce(pointers: [String: ActivePointer],
                         versions: [ProfileVersion]) async throws -> AnnounceResponse {
        try await announce(pointers: pointers, versions: versions, contents: nil)
    }

    private func announce(pointers: [String: ActivePointer], versions: [ProfileVersion],
                          contents: [String: String]?) async throws -> AnnounceResponse {
        let envelope = SyncAnnounceEnvelope(device: syncDevice, pointers: pointers,
                                            versions: versions, contents: contents)
        let body = try JSONEncoder.sync.encode(envelope)
        let reply = try await send(method: "POST", path: "/v1/announce", body: body)
        return try decode(AnnounceResponse.self, from: reply)
    }

    // MARK: One round

    /// Pull what the peer has, publish what this device has, and merge pointers
    /// from both answers so a single call is enough for two devices to converge.
    public func syncOnce() async throws -> SyncReport {
        var pulled: [String] = []
        var changed: [String] = []

        let manifest = try await fetchManifest()

        // 1. Pull every version the peer advertises and we lack.
        for version in store.missing(from: manifest.versions) {
            guard let data = try? await fetchVersion(id: version.id) else { continue }
            let meta = store.meta(id: version.id) ?? version
            guard (try? store.ingest(content: data, meta: meta)) != nil else { continue }
            pulled.append(version.id)
        }

        // 2. Adopt the peer's pointers; versions are already on disk at this point.
        changed.append(contentsOf: store.merge(pointers: manifest.pointers))

        // 3. Publish our state. The peer answers with what it still lacks.
        var response = try await announce(pointers: store.pointers(), versions: store.list())
        changed.append(contentsOf: store.merge(pointers: response.pointers))

        // 4. Close the gap in one extra round: push the content it asked for and
        //    take back pointers that only became applicable after the push.
        if !response.needVersions.isEmpty {
            let contents = pushPayload(for: response.needVersions)
            if !contents.isEmpty {
                response = try await announce(pointers: store.pointers(),
                                              versions: store.list(),
                                              contents: contents)
                changed.append(contentsOf: store.merge(pointers: response.pointers))
            }
        }

        let report = SyncReport(pulled: pulled,
                                pointersChanged: Array(Set(changed)).sorted(),
                                active: store.effectiveActiveVersion())
        TFLog.shared.debug("sync",
            "syncOnce pulled=\(pulled.count) pointers=\(report.pointersChanged.count) active=\(report.active ?? "nil")")
        return report
    }

    /// Canonical bytes for the ids the peer reported as missing, bounded by the
    /// server's body cap. Anything larger is left for the peer to pull.
    private func pushPayload(for ids: [String]) -> [String: String] {
        var contents: [String: String] = [:]
        var budget = Self.maxPushBytes
        for id in ids {
            guard let data = try? store.data(id: id) else { continue }
            let encoded = data.base64EncodedString()
            guard encoded.utf8.count <= budget else { continue }
            budget -= encoded.utf8.count
            contents[id] = encoded
        }
        return contents
    }

    private static func isVersionID(_ id: String) -> Bool {
        id.count == 64 && id.allSatisfy { $0.isHexDigit }
    }

    // MARK: HTTP

    private struct HTTPReply {
        var status: Int
        var body: Data
    }

    private func decode<T: Decodable>(_ type: T.Type, from reply: HTTPReply) throws -> T {
        do {
            return try JSONDecoder.sync.decode(type, from: reply.body)
        } catch {
            let text = String(data: reply.body.prefix(400), encoding: .utf8) ?? "<\(reply.body.count) bytes>"
            throw SyncError.malformedResponse("\(T.self): \(error.localizedDescription) body=\(text)")
        }
    }

    private func send(method: String, path: String, body: Data = Data(),
                      signed: Bool = true) async throws -> HTTPReply {
        let socket: NetSocket
        do {
            socket = try await NetSocket.connect(host: host, port: port, timeout: timeout)
        } catch {
            throw SyncError.transport("connect \(host):\(port) failed: \(error)")
        }
        defer { socket.close() }

        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: \(host):\(port)\r\n"
        head += "User-Agent: tfctl-sync/1\r\n"
        head += "Accept: application/json\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        if signed {
            let headers = SyncAuth.headers(identity: identity, method: method, path: path, body: body)
            for key in headers.keys.sorted() {
                head += "\(key): \(headers[key] ?? "")\r\n"
            }
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var wire = Data(head.utf8)
        wire.append(body)
        do {
            try await socket.write(wire)
        } catch {
            throw SyncError.transport("write \(path) failed: \(error)")
        }

        let reply = try await readReply(from: socket, path: path)
        guard (200..<300).contains(reply.status) else {
            let text = String(data: reply.body.prefix(512), encoding: .utf8) ?? ""
            if !text.isEmpty {
                TFLog.shared.debug("sync", "\(method) \(path) -> \(reply.status) \(text)")
            }
            throw SyncError.http(reply.status)
        }
        return reply
    }

    private func readReply(from socket: NetSocket, path: String) async throws -> HTTPReply {
        var buffer = Data()
        var headerEnd: Range<Data.Index>?
        let separator = Data("\r\n\r\n".utf8)

        while headerEnd == nil {
            guard let chunk = try await socket.read(maxLength: 16 * 1024) else { break }
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if buffer.count > Self.maxResponseBytes + SyncServer.maxHeaderBytes {
                throw SyncError.malformedResponse("response head too large")
            }
            headerEnd = buffer.range(of: separator)
        }
        guard let headerEnd else {
            throw SyncError.malformedResponse("no header terminator for \(path)")
        }
        guard let headText = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            throw SyncError.malformedResponse("non-UTF8 response head")
        }
        let lines = headText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw SyncError.malformedResponse("empty status line")
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw SyncError.malformedResponse("bad status line \(statusLine)")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        var body = Data(buffer[headerEnd.upperBound...])
        if let raw = headers["content-length"], let expected = Int(raw) {
            guard expected <= Self.maxResponseBytes else {
                throw SyncError.malformedResponse("declared body too large (\(expected))")
            }
            while body.count < expected {
                guard let chunk = try await socket.read(maxLength: 64 * 1024), !chunk.isEmpty else { break }
                body.append(chunk)
            }
            guard body.count >= expected else {
                throw SyncError.malformedResponse("truncated body \(body.count)/\(expected)")
            }
            body = body.prefix(expected)
        } else {
            while let chunk = try await socket.read(maxLength: 64 * 1024), !chunk.isEmpty {
                body.append(chunk)
                if body.count > Self.maxResponseBytes {
                    throw SyncError.malformedResponse("body exceeds \(Self.maxResponseBytes) bytes")
                }
            }
        }
        return HTTPReply(status: status, body: body)
    }
}
