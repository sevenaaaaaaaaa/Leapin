import XCTest
@testable import LeapinControl
import LeapinCore

/// Transport-level tests: a real `ControlServer` on a loopback port, exercised over
/// URLSession exactly like the remote CLI does. No engine involved — the backend is a
/// scripted fake, so failures point at the HTTP surface rather than at routing.
@MainActor
final class ControlServerTests: XCTestCase {
    private var tempDir: URL!
    private var server: ControlServer!
    private var backend: FakeBackend!

    private var tokenURL: URL { tempDir.appendingPathComponent("control-token") }
    private var auditURL: URL { tempDir.appendingPathComponent("control-audit.jsonl") }

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leapin-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        backend = FakeBackend()
        server = try startServer()
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    /// Port 0 lets the kernel pick; if the runtime refuses an ephemeral port we fall
    /// back to a random high port. Never a fixed 7900, so parallel runs cannot clash.
    private func startServer() throws -> ControlServer {
        var candidates: [UInt16] = [0]
        candidates.append(contentsOf: (0..<8).map { _ in UInt16.random(in: 20_000...50_000) })
        var lastError: Error?
        for port in candidates {
            let configuration = ControlServer.Configuration(
                port: port,
                allowLAN: false,
                tokenFile: tokenURL,
                auditFile: auditURL)
            do {
                let candidate = try ControlServer(configuration: configuration, backend: backend)
                try candidate.start()
                return candidate
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ControlError.unavailable("no control port available")
    }

    // MARK: HTTP helpers

    private func url(_ path: String) throws -> URL {
        let port = try XCTUnwrap(server.listeningPort)
        return try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
    }

    private func send(_ path: String, method: String = "GET", token: String? = nil,
                      body: [String: Any] = [:]) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if !body.isEmpty {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, object)
    }

    // MARK: Token file

    func testTokenFileIsGeneratedWithTightPermissions() throws {
        let raw = try String(contentsOf: tokenURL, encoding: .utf8)
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(token, server.token, "server.token must be the file contents")
        XCTAssertEqual(token.count, 64, "32 random bytes hex-encoded")
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit })

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: tokenURL.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600,
                       "token file must be 0600")

        let dirAttributes = try FileManager.default.attributesOfItem(atPath: tempDir.path)
        XCTAssertEqual((dirAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700,
                       "token directory must be 0700")
    }

    func testExistingTokenIsReused() throws {
        let first = server.token
        server.stop()
        let second = try ControlServer(configuration: ControlServer.Configuration(
            port: 0, tokenFile: tokenURL, auditFile: auditURL), backend: backend)
        XCTAssertEqual(second.token, first, "restart must keep the token clients saved")
        try second.start()
        server = second
    }

    // MARK: Auth

    func testMissingTokenIs401AndAudited() async throws {
        let (status, object) = try await send("/v1/status")
        XCTAssertEqual(status, 401)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "unauthorized")
        XCTAssertNotNil(object["message"])

        let records = try auditRecords()
        let record = try XCTUnwrap(records.last)
        XCTAssertEqual(record.path, "/v1/status")
        XCTAssertEqual(record.status, 401)
        XCTAssertFalse(record.allowed)
        XCTAssertEqual(record.method, "GET")
        XCTAssertTrue(record.remote.hasPrefix("127.0.0.1:"), record.remote)
    }

    func testBearerTokenIsAccepted() async throws {
        let (status, object) = try await send("/v1/status", token: server.token)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["engineState"] as? String, "running")
        XCTAssertEqual(object["controlPort"] as? Int, 7900)
        XCTAssertEqual(object["ruleCount"] as? Int, 42)
    }

    func testXHeaderAndQueryTokenAreAccepted() async throws {
        var request = URLRequest(url: try url("/v1/status"))
        request.setValue(server.token, forHTTPHeaderField: "X-Leapin-Token")
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        XCTAssertEqual(object?["ok"] as? Bool, true)

        let (queryStatus, queryObject) = try await send("/v1/status?token=\(server.token)")
        XCTAssertEqual(queryStatus, 200)
        XCTAssertEqual(queryObject["ok"] as? Bool, true)
    }

    func testWrongTokenIs401() async throws {
        let (status, object) = try await send("/v1/status", token: "definitely-not-the-token")
        XCTAssertEqual(status, 401)
        XCTAssertEqual(object["ok"] as? Bool, false)
    }

    // MARK: Routing

    func testReloadReturnsResultShape() async throws {
        let (status, object) = try await send("/v1/reload", method: "POST", token: server.token)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["restarted"] as? Bool, false)
        XCTAssertEqual(object["applied"] as? [String], ["rules", "profile"])
        XCTAssertEqual(object["skipped"] as? [String], ["dns"])
        XCTAssertEqual(object["ruleCount"] as? Int, 42)
        XCTAssertNotNil(object["elapsedMs"] as? Double)
        XCTAssertEqual(backend.reloadCount, 1)
    }

    func testUnknownPathIs404() async throws {
        let (status, object) = try await send("/v1/nope", token: server.token)
        XCTAssertEqual(status, 404)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "not_found")
    }

    func testWrongMethodIs405() async throws {
        let (status, object) = try await send("/v1/status", method: "POST", token: server.token)
        XCTAssertEqual(status, 405)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "method_not_allowed")
    }

    func testConnectionsAndPoliciesRoutes() async throws {
        let (connectionsStatus, connections) = try await send("/v1/connections?limit=5", token: server.token)
        XCTAssertEqual(connectionsStatus, 200)
        XCTAssertEqual(connections["count"] as? Int, 1)
        XCTAssertEqual(backend.lastConnectionLimit, 5)

        let (policiesStatus, policies) = try await send("/v1/policies", token: server.token)
        XCTAssertEqual(policiesStatus, 200)
        XCTAssertEqual(policies["count"] as? Int, 1)
    }

    func testSelectRouteReachesBackend() async throws {
        let (status, object) = try await send("/v1/policies/select", method: "POST",
                                              token: server.token,
                                              body: ["group": "Proxy", "outbound": "HK-01"])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["effective"] as? String, "HK-01")
        XCTAssertEqual(backend.lastSelection, ["Proxy", "HK-01"])
    }

    func testAuditRouteReturnsRecords() async throws {
        _ = try await send("/v1/status", token: server.token)
        let (status, object) = try await send("/v1/audit?limit=10", token: server.token)
        XCTAssertEqual(status, 200)
        let records = object["records"] as? [[String: Any]] ?? []
        XCTAssertFalse(records.isEmpty)
        XCTAssertTrue(records.contains { ($0["path"] as? String) == "/v1/status" })
    }

    // MARK: SSE

    func testSSEDeliversReplayAndLiveEvent() async throws {
        let token = server.token
        // Seed the replay buffer before any client attaches.
        try await publish(timestampMs: 1_000, host: "replay.example.com")

        let eventURL = try url("/v1/events?since=0")

        let session = URLSession(configuration: .ephemeral)
        let stream = Task<String, Error> {
            var request = URLRequest(url: eventURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw ControlError.unavailable("SSE status \(status)") }
            var accumulated = ""
            for try await line in bytes.lines {
                accumulated += line + "\n"
                if accumulated.contains("live.example.com") { return accumulated }
            }
            return accumulated
        }

        // Wait (bounded) for the subscription to register, then publish live.
        let deadline = Date().addingTimeInterval(5)
        while server.sseClientCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(server.sseClientCount, 0, "SSE client never registered")
        try await publish(timestampMs: 2_000, host: "live.example.com")

        let received = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await stream.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw ControlError.unavailable("timed out waiting for SSE frame")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? ""
        }
        stream.cancel()
        // AsyncBytes does not cancel its URLSessionTask on early exit; tear the
        // whole session down so the server observes the disconnect.
        session.invalidateAndCancel()

        XCTAssertTrue(received.contains("event: flow"), received)
        XCTAssertTrue(received.contains("data: "), received)
        XCTAssertTrue(received.contains("replay.example.com"), received)
        XCTAssertTrue(received.contains("live.example.com"), received)
        XCTAssertTrue(received.contains("id: "), received)

        // Give the server a beat to observe disconnects, then assert cleanup.
        let cleanupDeadline = Date().addingTimeInterval(5)
        while server.sseClientCount > 0, Date() < cleanupDeadline {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(server.sseClientCount, 0, "disconnected SSE client was not cleaned up")
    }

    // MARK: Helpers

    private func publish(timestampMs: Double, host: String) async throws {
        server.publish(ControlEvent(
            timestampMs: timestampMs,
            phase: "opened",
            host: host,
            port: 443,
            policy: "DIRECT",
            matchedRule: "",
            outbound: "DIRECT",
            sourceApp: "XCTest"))
    }

    private func auditRecords() throws -> [ControlAuditRecord] {
        guard let data = try? Data(contentsOf: auditURL), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap {
            try? decoder.decode(ControlAuditRecord.self, from: Data($0))
        }
    }
}

// MARK: - Fake backend

@MainActor
private final class FakeBackend: ControlBackend {
    private(set) var reloadCount = 0
    private(set) var lastConnectionLimit = 0
    private(set) var lastSelection: [String] = []

    func controlStatus() async -> ControlStatus {
        ControlStatus(engineState: "running", mixedPort: 7890, httpPort: 7891, socksPort: 7892,
                      controlPort: 7900, ruleCount: 42, adblockRuleCount: 7,
                      activeConnections: 3, systemProxyActive: false, uptimeSeconds: 12)
    }

    func controlConnections(limit: Int) async -> [ControlConnection] {
        lastConnectionLimit = limit
        return [ControlConnection(id: "c1", timestampMs: 1_000, phase: "opened",
                                  host: "example.com", port: 443, network: "tcp",
                                  policy: "DIRECT", matchedRule: "", outbound: "DIRECT",
                                  sourceApp: "Safari", sourcePID: 1, bytesIn: 10,
                                  bytesOut: 20, durationMs: 30)]
    }

    func controlPolicies() async -> [ControlPolicyGroup] {
        [ControlPolicyGroup(name: "Proxy", type: "select", selected: "HK-01",
                            effective: "HK-01", members: ["HK-01", "DIRECT"])]
    }

    func controlSelect(group: String, outbound: String) async throws -> ControlSelectionResult {
        lastSelection = [group, outbound]
        return ControlSelectionResult(group: group, outbound: outbound,
                                      effective: outbound, persisted: true)
    }

    func controlReload() async throws -> ControlReloadResult {
        reloadCount += 1
        return ControlReloadResult(restarted: false, applied: ["rules", "profile"],
                                   skipped: ["dns"], ruleCount: 42, elapsedMs: 1.5)
    }

    func controlExplain(host: String, port: Int) async throws -> ControlExplainResult {
        ControlExplainResult(host: host, port: port, policy: "DIRECT", matchedRule: "",
                             trace: ["host=\(host)"] )
    }

    func controlDNSTrace(host: String) async throws -> DNSTrace {
        DNSTrace(host: host, source: .cache, resolved: ["127.0.0.1"])
    }

    func controlHTTPProbe(url: String, timeoutMs: Int) async throws -> HTTPProbeResult {
        HTTPProbeResult(url: url, statusCode: 204, elapsedMs: 5)
    }
}