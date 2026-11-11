import XCTest
import Network
import Darwin
import LeapinCore
import LeapinNet
import LeapinPolicy
import LeapinIntegrations
@testable import LeapinRuntime

private final class LocalOrigin: @unchecked Sendable {
    let listener: NWListener
    private let redirect: String?
    init(parameters: NWParameters = .tcp, redirect: String? = nil) throws { self.redirect = redirect; listener = try NWListener(using: parameters, on: .any) }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { _, _, _, _ in
                let body = "leapin-managed-kernel-e2e"
                let redirectHeader = self.redirect.map { "Location: \($0)\r\n" } ?? ""
                let response = "HTTP/1.1 \(self.redirect == nil ? "200 OK" : "302 Found")\r\n\(redirectHeader)Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let port = self?.listener.port?.rawValue { continuation.resume(returning: port) }
                if case .failed(let error) = state { continuation.resume(throwing: error) }
            }
            listener.start(queue: .global())
        }
    }
    func stop() { listener.cancel() }
}

private final class LocalDatagramServer: @unchecked Sendable {
    let listener: NWListener
    var connections: [NWConnection] = []
    let transform: @Sendable (Data) -> Data
    init(transform: @escaping @Sendable (Data) -> Data) throws {
        self.transform = transform; listener = try NWListener(using: .udp, on: .any)
    }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { connection in
            self.connections.append(connection)
            connection.start(queue: .global()); self.receive(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: self.listener.port!.rawValue)
                case .failed(let error): self.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }
    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { data, _, _, error in
            if let data { connection.send(content: self.transform(data), completion: .contentProcessed { _ in }) }
            if error == nil { self.receive(connection) }
        }
    }
    func stop() { listener.cancel(); connections.forEach { $0.cancel() } }
}

final class ManagedKernelRuntimeTests: XCTestCase {
    private static let rawSource = """
    proxies:
      - name: VLESS-test-node
        type: vless
        server: 192.0.2.1
        port: 443
        uuid: 11111111-1111-4111-8111-111111111111
        tls: true
    proxy-groups:
      - name: Route
        type: select
        proxies: [DIRECT, REJECT, VLESS-test-node]
    rules:
      - MATCH,Route
    """

    private func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LeapinError.connectionFailed("socket") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw LeapinError.connectionFailed("bind") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    @MainActor
    private func makeEngine(root: URL) throws -> LeapinEngine {
        let store = ProfileStore(root: root)
        let port = try availablePort()
        let profile = Profile(name: "Previous", general: GeneralConfig(mixedPort: port, httpPort: 0, socksPort: 0,
            captureEnabled: false, dnsHijack: false, controlEnabled: false),
            rules: [Rule(kind: .match, value: "", policy: "DIRECT")])
        _ = try store.save(profile)
        store.activeProfileID = profile.id
        return LeapinEngine(store: store)
    }

    private func getThroughProxy(port: UInt16, origin: UInt16) async throws -> String {
        let socket = try await NetSocket.connect(host: "127.0.0.1", port: port, timeout: 5)
        defer { socket.close() }
        try await socket.write(Data("GET http://127.0.0.1:\(origin)/ HTTP/1.1\r\nHost: 127.0.0.1:\(origin)\r\nConnection: close\r\n\r\n".utf8))
        var received = Data()
        while let data = try await socket.read(maxLength: 16_384), !data.isEmpty {
            received.append(data)
            if received.count > 64_000 { break }
        }
        return String(decoding: received, as: UTF8.self)
    }

    @MainActor
    func testRealMihomoImportRoutesTrafficAndRestoresNativeProfile() async throws {
        guard KernelExecutable.mihomo() != nil else { throw XCTSkip("Mihomo executable is not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leapin-kernel-\(UUID().uuidString)")
        let engine = try makeEngine(root: root)
        let origin = try LocalOrigin()
        defer { engine.stop(); origin.stop(); try? FileManager.default.removeItem(at: root) }
        let originPort = try await origin.start()
        let oldID = engine.profile.id
        await engine.start()
        XCTAssertEqual(engine.state, .running)
        let preparation = try ImportPreparation(text: Self.rawSource, name: "Mixed subscription")
        XCTAssertFalse(preparation.nativeBlockers.isEmpty)
        try await engine.commitImport(preparation, kernel: .mihomo)
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.executionKernel, .mihomo)
        XCTAssertTrue(engine.managedKernel.running)
        XCTAssertFalse(engine.systemProxyActive)
        XCTAssertEqual(try engine.exportProfile(.clash), Self.rawSource)
        XCTAssertThrowsError(try engine.exportProfile(.surge))
        XCTAssertThrowsError(try engine.commitTaskRules(expected: engine.profile, rules: []))
        let explain = try await engine.controlExplain(host: "127.0.0.1", port: Int(originPort))
        XCTAssertEqual(explain.outbound, "Mihomo")
        let response = try await getThroughProxy(port: engine.profile.general.mixedPort, origin: originPort)
        XCTAssertTrue(response.contains("200 OK"), response)
        XCTAssertTrue(response.contains("leapin-managed-kernel-e2e"), response)
        let groups = try await engine.managedPolicies()
        XCTAssertEqual(groups.first(where: { $0.name == "Route" })?.selected, "DIRECT")
        try await engine.selectManagedPolicy(group: "Route", member: "REJECT")
        XCTAssertEqual(try engine.store.kernelSource(for: engine.profile.id)?.selections?["Route"], "REJECT")
        try await engine.selectManagedPolicy(group: "Route", member: "DIRECT")
        await engine.reloadProfile()
        XCTAssertEqual(engine.state, .running)
        XCTAssertEqual(engine.executionKernel, .mihomo)
        // Overlay a fixture resource without touching the actual tailnet or dialing it.
        let peer = TailnetPeer(id: "fixture-home", hostname: "NAS", dnsName: "nas.fixture.ts.net.", addresses: ["100.64.1.2"], online: true)
        let home = try HomeConnection(snapshot: TailnetSnapshot(state: "Running", selfID: "fixture-self", peers: [peer]), peer: peer, resource: "https://nas.fixture.ts.net")
        try HomeConnection.save(home, root: root)
        try engine.refreshHomeRouting()
        let homeRoute = try await engine.controlExplain(host: home.host, port: 443)
        XCTAssertEqual(homeRoute.outbound, "DIRECT")
        let otherRoute = try await engine.controlExplain(host: "unrelated.fixture.test", port: 443)
        XCTAssertEqual(otherRoute.outbound, "Mihomo")
        let homeDNS = try await engine.controlDNSTrace(host: home.host)
        XCTAssertEqual(homeDNS.source, .hosts)
        XCTAssertEqual(homeDNS.resolved, [home.address])
        await engine.reloadProfile()
        let homeAfterReload = try await engine.controlExplain(host: home.host, port: 443)
        XCTAssertEqual(homeAfterReload.outbound, "DIRECT")
        let reloadedGroups = try await engine.managedPolicies()
        XCTAssertEqual(reloadedGroups.first(where: { $0.name == "Route" })?.selected, "DIRECT")
        await engine.activate(oldID)
        XCTAssertEqual(engine.profile.id, oldID)
        XCTAssertEqual(engine.executionKernel, .native)
        XCTAssertEqual(engine.state, .running)
        XCTAssertFalse(engine.managedKernel.running)
    }

    @MainActor
    func testHomeOverlayAppliesToLiveNativeRoutingReloadAndRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leapin-home-routing-\(UUID().uuidString)")
        let engine = try makeEngine(root: root)
        defer { engine.stop(); try? FileManager.default.removeItem(at: root) }
        engine.updateProfile { $0.rules = [Rule(kind: .match, value: "", policy: "REJECT")] }
        let original = engine.profile
        let peer = TailnetPeer(id: "home", hostname: "NAS", dnsName: "nas.fixture.ts.net.", addresses: ["100.64.1.2"], online: true)
        let home = try HomeConnection(snapshot: TailnetSnapshot(state: "Running", selfID: "self", peers: [peer]), peer: peer, resource: "https://nas.fixture.ts.net")
        try HomeConnection.save(home, root: root)
        await engine.start()
        XCTAssertEqual(engine.state, .running)
        let route = try await engine.controlExplain(host: home.host, port: 443)
        XCTAssertEqual(route.outbound, "DIRECT")
        let other = try await engine.controlExplain(host: "other.fixture.test", port: 443)
        XCTAssertTrue(other.isBlocked)
        let dns = try await engine.controlDNSTrace(host: home.host)
        XCTAssertEqual(dns.resolved, ["100.64.1.2"])
        XCTAssertEqual(engine.profile, original)
        await engine.reloadProfile()
        let reloaded = try await engine.controlExplain(host: home.host, port: 443)
        XCTAssertEqual(reloaded.outbound, "DIRECT")
        try HomeConnection.save(nil, root: root)
        try engine.refreshHomeRouting()
        let removed = try await engine.controlExplain(host: home.host, port: 443)
        XCTAssertTrue(removed.isBlocked)
        XCTAssertFalse(engine.systemProxyActive)
    }

    @MainActor
    func testSourceDNSPolicyControlsActualProxyRequestAndTrace() async throws {
        guard KernelExecutable.mihomo() != nil else { throw XCTSkip("Mihomo not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leapin-source-dns-\(UUID().uuidString)")
        let engine = try makeEngine(root: root); let origin = try LocalOrigin()
        let dns = try LocalDatagramServer { data in
            guard let query = try? DNSMessage.decode(data), let question = query.questions.first else { return Data() }
            let answers: [DNSResourceRecord] = question.type == .a ? [DNSResourceRecord(name: question.name, type: .a, ttl: 123, rdata: Data([127, 0, 0, 1]))] : []
            return DNSMessage.reply(to: query, rcode: .noError, answers: answers).encode()
        }
        defer { engine.stop(); origin.stop(); dns.stop(); try? FileManager.default.removeItem(at: root) }
        let dnsPort = try await dns.start(); let originPort = try await origin.start()
        let source = """
        dns:
          enable: true
          ipv6: false
          enhanced-mode: redir-host
          nameserver: [udp://127.0.0.1:9]
          nameserver-policy:
            policy.fixture.invalid: [udp://127.0.0.1:\(dnsPort)]
        proxies: []
        rules: ['MATCH,DIRECT']
        """
        try await engine.commitImport(ImportPreparation(text: source, name: "DNS policy fixture"), kernel: .mihomo)
        let trace = try await engine.controlDNSTrace(host: "policy.fixture.invalid")
        XCTAssertNil(trace.error); XCTAssertTrue(trace.resolved.contains("127.0.0.1"))
        XCTAssertEqual(trace.upstream, "Mihomo 来源 DNS 策略")
        let client = try await NetSocket.connect(host: "127.0.0.1", port: engine.profile.general.mixedPort, timeout: 3)
        defer { client.close() }
        try await client.write(Data("GET http://policy.fixture.invalid:\(originPort)/ HTTP/1.1\r\nHost: policy.fixture.invalid:\(originPort)\r\nConnection: close\r\n\r\n".utf8))
        let response = try await client.read(maxLength: 8192)
        XCTAssertTrue(String(decoding: response ?? Data(), as: UTF8.self).contains("200 OK"))
        XCTAssertFalse(engine.systemProxyActive)
    }

    @MainActor
    func testSOCKSUDPAssociationReachesRealMihomoAndLocalDatagramTarget() async throws {
        guard KernelExecutable.mihomo() != nil else { throw XCTSkip("Mihomo not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leapin-udp-\(UUID().uuidString)")
        let engine = try makeEngine(root: root)
        let echo = try LocalDatagramServer { $0 }
        defer { engine.stop(); echo.stop(); try? FileManager.default.removeItem(at: root) }
        let destination = try await echo.start()
        try await engine.commitImport(ImportPreparation(text: "proxies: []\nrules: ['MATCH,DIRECT']", name: "UDP fixture"), kernel: .mihomo)
        let control = try await NetSocket.connect(host: "127.0.0.1", port: engine.profile.general.mixedPort, timeout: 3)
        defer { control.close() }
        let stream = BufferedStream(control)
        try await stream.write(Data([5, 1, 0]))
        let greeting = try await stream.readExactly(2); XCTAssertEqual(Array(greeting), [5, 0])
        try await stream.write(SOCKS5.requestHeader(host: "0.0.0.0", port: 0, command: .udpAssociate)!)
        let reply = try await stream.readExactly(3); XCTAssertEqual(Array(reply), [5, 0, 0])
        let (host, port) = try await SOCKS5.decodeAddress(stream)
        XCTAssertEqual(host, "127.0.0.1"); XCTAssertGreaterThan(port, 0)
        var packet = Data([0, 0, 0]); packet.append(SOCKS5.encodeAddress(host: "127.0.0.1", port: destination)!)
        packet.append(Data("udp-fixture-payload".utf8))
        let response = try await DNSDatagram.exchange(host: host, port: port, payload: packet, timeout: 3)
        XCTAssertTrue(String(decoding: response.suffix("udp-fixture-payload".utf8.count), as: UTF8.self) == "udp-fixture-payload")
        XCTAssertFalse(engine.systemProxyActive)
    }

    @MainActor
    func testRealMitmproxyMetadataFlowsThroughMihomo() async throws {
        guard KernelExecutable.mihomo() != nil, let executable = ProcessInfo.processInfo.environment["LEAPIN_TEST_MITMDUMP_PATH"] else { throw XCTSkip("Set LEAPIN_TEST_MITMDUMP_PATH for real mitmproxy integration") }
        let old = ProcessInfo.processInfo.environment["LEAPIN_MITMDUMP_PATH"]
        setenv("LEAPIN_MITMDUMP_PATH", executable, 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leapin-mitm-\(UUID().uuidString)")
        let engine = try makeEngine(root: root); let origin = try LocalOrigin(); let debug = DebugChannel(root: root)
        defer {
            debug.stop(force: true); engine.stop(); origin.stop()
            if let old { setenv("LEAPIN_MITMDUMP_PATH", old, 1) } else { unsetenv("LEAPIN_MITMDUMP_PATH") }
            try? FileManager.default.removeItem(at: root)
        }
        let port = try await origin.start()
        try await engine.commitImport(ImportPreparation(text: "proxies: []\nrules: ['MATCH,DIRECT']", name: "Debug fixture"), kernel: .mihomo)
        await debug.start(try DebugChannelPlan(host: "127.0.0.1", upstreamPort: engine.managedKernel.proxyPort!))
        XCTAssertNotNil(debug.port, debug.message ?? "")
        guard let proxyPort = debug.port else { return }
        let response = try await getThroughProxy(port: proxyPort, origin: port)
        XCTAssertTrue(response.contains("200 OK"))
        try await Task.sleep(nanoseconds: 200_000_000); debug.refresh()
        XCTAssertEqual(debug.requests.last?.status, 200)
        let metadata = try String(contentsOf: debug.directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        XCTAssertFalse(metadata.contains("leapin-managed-kernel-e2e"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: debug.certificateURL.path))
    }

    @MainActor
    func testRealMitmproxyDecryptsHTTPSWithoutChangingSystemTrust() async throws {
        guard KernelExecutable.mihomo() != nil, let executable = ProcessInfo.processInfo.environment["LEAPIN_TEST_MITMDUMP_PATH"] else { throw XCTSkip("Requires opt-in real mitmproxy") }
        let old = ProcessInfo.processInfo.environment["LEAPIN_MITMDUMP_PATH"]; setenv("LEAPIN_MITMDUMP_PATH", executable, 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leapin-https-debug-\(UUID().uuidString)")
        let engine = try makeEngine(root: root); let debug = DebugChannel(root: root)
        let ca = try CertificateAuthority(directory: root.appendingPathComponent("origin-ca"))
        let identity = try ca.identity(for: "127.0.0.1")
        let origin = try LocalOrigin(parameters: TLSFactory.tcpParameters(tls: TLSFactory.serverOptions(identity: identity, alpn: ["http/1.1"])))
        defer {
            debug.stop(force: true); engine.stop(); origin.stop()
            if let old { setenv("LEAPIN_MITMDUMP_PATH", old, 1) } else { unsetenv("LEAPIN_MITMDUMP_PATH") }
            try? FileManager.default.removeItem(at: root)
        }
        let port = try await origin.start()
        try await engine.commitImport(ImportPreparation(text: "proxies: []\nrules: ['MATCH,DIRECT']", name: "HTTPS fixture"), kernel: .mihomo)
        await debug.start(try DebugChannelPlan(host: "127.0.0.1", upstreamPort: engine.managedKernel.proxyPort!, upstreamCA: ca.caCertificateURL))
        guard let proxyPort = debug.port else { XCTFail(debug.message ?? "No debug port"); return }
        let certificatePath = debug.certificateURL.path
        let response = try await Task.detached {
            try CommandRunner.run(executable: "/usr/bin/curl", arguments: ["--silent", "--show-error", "--noproxy", "", "--proxy", "http://127.0.0.1:\(proxyPort)", "--cacert", certificatePath, "--max-time", "8", "https://127.0.0.1:\(port)/private?token=fixture-secret"], timeout: 10)
        }.value
        XCTAssertEqual(response.status, 0, response.stderr)
        XCTAssertTrue(response.stdout.contains("leapin-managed-kernel-e2e"))
        try await Task.sleep(nanoseconds: 100_000_000); debug.refresh()
        XCTAssertFalse(debug.process.logs.contains("fixture-secret"))
        XCTAssertFalse(debug.process.logs.contains("/private"))
        XCTAssertEqual(debug.requests.last?.scheme, "https")
        XCTAssertEqual(debug.requests.last?.status, 200)
        let metadata = try String(contentsOf: debug.directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        XCTAssertFalse(metadata.contains("fixture-secret")); XCTAssertFalse(metadata.contains("/private"))
        XCTAssertFalse(engine.systemProxyActive)
    }

    @MainActor
    func testShareFixtureRequiresLocalResponseThenOwnsAndStopsLink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leapin-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("cloudflared-fixture")
        try Data("#!/bin/sh\nif [ \"$2\" = --help ]; then echo --allowed-mail; exit 0; fi\necho https://leapin-fixture.trycloudflare.com\necho 'Registered tunnel connection'\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let old = ProcessInfo.processInfo.environment["LEAPIN_CLOUDFLARED_PATH"]; setenv("LEAPIN_CLOUDFLARED_PATH", executable.path, 1)
        let origin = try LocalOrigin(); let model = ServiceSharing()
        defer {
            model.stop(force: true); origin.stop()
            if let old { setenv("LEAPIN_CLOUDFLARED_PATH", old, 1) } else { unsetenv("LEAPIN_CLOUDFLARED_PATH") }
            try? FileManager.default.removeItem(at: root)
        }
        let port = try await origin.start()
        await model.start(try ServiceSharePlan(origin: "http://127.0.0.1:\(port)", minutes: 15, email: "dev@example.com", publicAccess: false))
        XCTAssertTrue(model.process.running, model.message ?? "")
        XCTAssertEqual(model.url?.host, "leapin-fixture.trycloudflare.com")
        XCTAssertNotNil(model.expiresAt)
        model.stop(force: true)
        XCTAssertNil(model.url); XCTAssertNil(model.expiresAt); XCTAssertFalse(model.process.running)
    }

    @MainActor
    func testRealTUNPreflightDoesNotCreateAnInterfaceOrStartKernel() async throws {
        guard KernelExecutable.mihomo() != nil else { throw XCTSkip("Mihomo not installed") }
        let before = "utun198".withCString { if_nametoindex($0) }
        let session = ManagedTUNSession()
        try await session.check(source: "proxies: []\nrules: ['MATCH,DIRECT']")
        XCTAssertFalse(session.kernel.running)
        XCTAssertEqual("utun198".withCString { if_nametoindex($0) }, before)
    }

    @MainActor
    func testShareExpiryStopsOwnedProcessAndRemovesLink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leapin-share-expiry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("cloudflared-fixture")
        try Data("#!/bin/sh\nif [ \"$2\" = --help ]; then echo --allowed-mail; exit 0; fi\necho https://leapin-expiry.trycloudflare.com\necho 'Registered tunnel connection'\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let old = ProcessInfo.processInfo.environment["LEAPIN_CLOUDFLARED_PATH"]; setenv("LEAPIN_CLOUDFLARED_PATH", executable.path, 1)
        let origin = try LocalOrigin(); let model = ServiceSharing(sleep: { delay in XCTAssertEqual(delay, 900_000_000_000) })
        defer {
            model.stop(force: true); origin.stop()
            if let old { setenv("LEAPIN_CLOUDFLARED_PATH", old, 1) } else { unsetenv("LEAPIN_CLOUDFLARED_PATH") }
            try? FileManager.default.removeItem(at: root)
        }
        let port = try await origin.start()
        await model.start(try ServiceSharePlan(origin: "http://127.0.0.1:\(port)", minutes: 15, email: "", publicAccess: true))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.process.running); XCTAssertNil(model.url); XCTAssertNil(model.expiresAt)
        XCTAssertTrue(model.message?.contains("到期") == true)
    }

    @MainActor
    func testCompanyDirectSystemDNSOverridesNativeAndMihomoWithoutChangingProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leapin-company-live-\(UUID().uuidString)")
        let engine = try makeEngine(root: root); let origin = try LocalOrigin()
        defer { engine.stop(); origin.stop(); try? FileManager.default.removeItem(at: root) }
        let port = try await origin.start()
        engine.updateProfile { $0.rules = [Rule(kind: .match, value: "", policy: "REJECT")]; $0.dns.hosts["localhost"] = "192.0.2.99" }
        let original = engine.profile
        await engine.start()
        let model = CompanyAccess(root: root)
        let resource = try CompanyResource(title: "Local company fixture", address: "http://localhost:\(port)/private?item=1")
        let company = CompanyConnection(name: "Fixture company", resources: [resource])
        try model.save(company, expected: nil, apply: { try engine.refreshHomeRouting() })
        let route = try await engine.controlExplain(host: "localhost", port: Int(port))
        XCTAssertEqual(route.outbound, company.policyName)
        let trace = try await engine.controlDNSTrace(host: "localhost")
        XCTAssertFalse(trace.resolved.contains("192.0.2.99")); XCTAssertFalse(trace.resolved.isEmpty)
        XCTAssertEqual(engine.profile, original)
        let socket = try await NetSocket.connect(host: "127.0.0.1", port: engine.profile.general.mixedPort, timeout: 3)
        defer { socket.close() }
        try await socket.write(Data("GET http://localhost:\(port)/ HTTP/1.1\r\nHost: localhost:\(port)\r\nConnection: close\r\n\r\n".utf8))
        let response = try await socket.read(maxLength: 8192)
        XCTAssertTrue(String(decoding: response ?? Data(), as: UTF8.self).contains("200 OK"))
        await engine.reloadProfile()
        let reloaded = try await engine.controlExplain(host: "localhost", port: Int(port))
        XCTAssertEqual(reloaded.outbound, company.policyName)
        if KernelExecutable.mihomo() != nil {
            try await engine.commitImport(ImportPreparation(text: "proxies: []\nrules: ['MATCH,REJECT']", name: "Company kernel fixture"), kernel: .mihomo)
            let external = try await engine.controlExplain(host: "localhost", port: Int(port))
            XCTAssertEqual(external.outbound, company.policyName)
            let other = try await engine.controlExplain(host: "unrelated.fixture.invalid", port: 443)
            XCTAssertEqual(other.outbound, "Mihomo")
        }
        try model.activate(nil, apply: { try engine.refreshHomeRouting() })
        let paused = try await engine.controlExplain(host: "localhost", port: Int(port))
        XCTAssertNotEqual(paused.outbound, company.policyName)
        XCTAssertFalse(engine.systemProxyActive)
    }

    @MainActor
    func testCompanyHTTPProxyKeepsTargetDNSAtProxyAndUsesSelectedRoute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leapin-company-proxy-\(UUID().uuidString)")
        let engine = try makeEngine(root: root); let origin = try LocalOrigin()
        let targetResolver = DNSResolver(config: DNSConfig(hosts: ["app.corp.fixture.invalid": "127.0.0.1"]))
        let targetProxy = ProxyServer(options: .init(port: 0), router: RuleEngine(profile: Profile(name: "Corporate proxy", rules: [Rule(kind: .match, value: "", policy: "DIRECT")])), resolver: targetResolver, blocker: nil, flows: nil, capture: nil)
        defer { targetProxy.stop(); engine.stop(); origin.stop(); try? FileManager.default.removeItem(at: root) }
        let port = try await origin.start(); try targetProxy.start()
        engine.updateProfile { $0.rules = [Rule(kind: .match, value: "", policy: "REJECT")] }
        await engine.start()
        let model = CompanyAccess(root: root)
        var company = CompanyConnection(name: "Proxy fixture", method: .httpProxy, resources: [try CompanyResource(title: "App", address: "http://app.corp.fixture.invalid:\(port)/")])
        company.proxy = URL(string: "http://127.0.0.1:\(targetProxy.listeningPort)")
        try model.save(company, expected: nil, apply: { try engine.refreshHomeRouting() })
        let result = await CompanyWebProbe.probe(company.resources[0].origin, proxyPort: engine.profile.general.mixedPort)
        XCTAssertNil(result.error); XCTAssertEqual(result.statusCode, 200)
        XCTAssertFalse(engine.systemProxyActive)
    }

    func testCompanyWebProbeDoesNotFollowLoginRedirects() async throws {
        let target = try LocalOrigin(); let targetPort = try await target.start()
        let redirect = try LocalOrigin(redirect: "http://127.0.0.1:\(targetPort)/callback?token=fixture")
        let redirectPort = try await redirect.start()
        defer { redirect.stop(); target.stop() }
        let result = await CompanyWebProbe.probe(URL(string: "http://127.0.0.1:\(redirectPort)/")!, proxyPort: nil)
        XCTAssertEqual(result.statusCode, 302)
        XCTAssertNil(result.error)
    }

    @MainActor
    func testFailedExternalStartRestoresPreviousRunningProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leapin-rollback-\(UUID().uuidString)")
        let engine = try makeEngine(root: root)
        let fake = root.appendingPathComponent("fake-mihomo")
        try Data("#!/bin/sh\nif [ \"$1\" = \"-t\" ]; then exit 0; fi\necho runtime-failure >&2\nexit 7\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let previousOverride = ProcessInfo.processInfo.environment["LEAPIN_MIHOMO_PATH"]
        setenv("LEAPIN_MIHOMO_PATH", fake.path, 1)
        defer {
            if let previousOverride { setenv("LEAPIN_MIHOMO_PATH", previousOverride, 1) }
            else { unsetenv("LEAPIN_MIHOMO_PATH") }
            engine.stop(); try? FileManager.default.removeItem(at: root)
        }
        let oldID = engine.profile.id
        await engine.start()
        let candidate = try ImportPreparation(text: Self.rawSource, name: "Fails at runtime")
        do { try await engine.commitImport(candidate, kernel: .mihomo); XCTFail("must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("恢复"), error.localizedDescription) }
        XCTAssertEqual(engine.profile.id, oldID)
        XCTAssertEqual(engine.store.activeProfileID, oldID)
        XCTAssertEqual(engine.executionKernel, .native)
        XCTAssertEqual(engine.state, .running)
        XCTAssertFalse(engine.managedKernel.running)
        XCTAssertFalse(engine.systemProxyActive)
    }
}
