import XCTest
import LeapinCore
import LeapinNet
import LeapinPolicy
@testable import LeapinRuntime

private actor CompanyTestResolver: NameResolving {
    var asked: [String] = []
    let values: [String]
    init(_ values: [String] = []) { self.values = values }
    func resolve(_ host: String) async throws -> [String] {
        asked.append(host)
        guard !values.isEmpty else { throw LeapinError.connectionFailed("fixture DNS failed") }
        return values
    }
}

final class CompanyAccessTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leapin-company-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func connection(method: CompanyAccessMethod = .client) throws -> CompanyConnection {
        CompanyConnection(name: "Fixture company", method: method, resources: [try CompanyResource(title: "Git", address: "https://git.corp.fixture/path?item=1")])
    }
    func testResourcesSupportShortNamesIPv6AndPreserveOriginalLinks() throws {
        XCTAssertEqual(try CompanyResource(title: "", address: "git").host, "git")
        XCTAssertEqual(try CompanyResource(title: "", address: "smb://10.0.0.8/share").port, 445)
        XCTAssertEqual(try CompanyResource(title: "", address: "ssh://[fd00::2]:2222").port, 2222)
        let resource = try CompanyResource(title: "Git", address: "https://git.corp.fixture/private?item=1#section")
        XCTAssertEqual(resource.origin.absoluteString, "https://git.corp.fixture/")
        XCTAssertEqual(resource.url.query, "item=1")
        XCTAssertTrue(resource.matchesProxyBypass(["*.corp.fixture"]))
        XCTAssertTrue(try CompanyResource(title: "", address: "http://10.0.0.8").matchesProxyBypass(["10.0.0.0/8"]))
        XCTAssertTrue(try CompanyResource(title: "", address: "git").matchesProxyBypass(["<local>"]))
        XCTAssertFalse(resource.matchesProxyBypass(["10.0.0.0/8"]))
        for text in ["https://name:secret@git.corp", "file:///tmp/private", "javascript:alert(1)", "https://git:0", "https://git:65536", "git other", "https://git..corp"] {
            XCTAssertThrowsError(try CompanyResource(title: "", address: text), text)
        }
    }
    func testDirectOverlayOnlyAffectsExactHostsAndNeverChangesSource() throws {
        let company = try connection()
        let original = Profile(name: "Base", rules: [Rule(kind: .match, value: "", policy: "REJECT")])
        let routed = try company.routing(original)
        XCTAssertEqual(routed.dns, original.dns)
        XCTAssertEqual(Array(routed.rules.dropFirst()), original.rules)
        let router = RuleEngine(profile: routed)
        XCTAssertEqual(router.decide(ConnectionMeta(host: "git.corp.fixture", port: 443)).outbound.type, .direct)
        XCTAssertTrue(router.decide(ConnectionMeta(host: "sub.git.corp.fixture", port: 443)).isBlocked)
        XCTAssertTrue(router.decide(ConnectionMeta(host: "unrelated.example", port: 443)).isBlocked)
        XCTAssertEqual(original.outbounds.count + 1, routed.outbounds.count)
    }
    func testBrowserAndProxyUseDistinctRoutingScopesAndNoProxyCredentials() throws {
        var browser = try connection(method: .browser); browser.portal = URL(string: "https://login.fixture.example/")
        let original = Profile(name: "Base")
        XCTAssertEqual(try browser.routing(original), original)
        XCTAssertTrue(browser.systemDNSHosts.isEmpty)
        var proxy = try connection(method: .httpProxy); proxy.proxy = URL(string: "https://proxy.corp.fixture:8443")
        XCTAssertEqual(proxy.systemDNSHosts, ["proxy.corp.fixture"])
        XCTAssertEqual(try proxy.proxyOutbound().type, .http)
        XCTAssertTrue(try proxy.proxyOutbound().tls)
        proxy.proxy = URL(string: "http://name:secret@proxy.corp:8080")
        XCTAssertThrowsError(try proxy.validate())
        proxy.method = .client
        XCTAssertThrowsError(try proxy.validate(), "Unused proxy fields must not hide credentials")
    }
    func testValidationRejectsProxyLoopsHomeConflictAndTransientSSO() throws {
        var company = try connection(method: .socksProxy)
        company.proxy = URL(string: "socks5://localhost:7890")
        XCTAssertThrowsError(try company.validateLoops(ports: [7890], homeHost: nil))
        company = try connection()
        XCTAssertThrowsError(try company.validateLoops(ports: [7890], homeHost: "git.corp.fixture"))
        company.portal = URL(string: "https://login.fixture/callback?code=one-time")
        XCTAssertThrowsError(try company.validate())
        company = try connection(method: .systemVPN)
        XCTAssertThrowsError(try company.validate())
        company = try connection()
        company.resources[0].url = URL(string: "relative")!
        XCTAssertThrowsError(try company.validate())
    }
    func testSystemScopedResolverNeverFallsBackToPublicResolver() async throws {
        let system = CompanyTestResolver(["10.0.0.2"]); let fallback = CompanyTestResolver(["192.0.2.1"])
        let resolver = CompanyScopedResolver(base: fallback, hosts: ["git.corp.fixture"], system: system)
        let resolved = try await resolver.resolve("GIT.corp.fixture.")
        XCTAssertEqual(resolved, ["10.0.0.2"])
        let subdomain = try await resolver.resolve("sub.git.corp.fixture")
        XCTAssertEqual(subdomain, ["192.0.2.1"])
        let failing = CompanyScopedResolver(base: fallback, hosts: ["private.corp"], system: CompanyTestResolver())
        do { _ = try await failing.resolve("private.corp"); XCTFail("No public fallback") } catch {}
        let asks = await fallback.asked
        XCTAssertEqual(asks, ["sub.git.corp.fixture"])
    }
    @MainActor
    func testStoreSurvivesRelaunchAndRollsBackFailedRouteUpdates() throws {
        let root = try root(); let model = CompanyAccess(root: root)
        let company = try connection()
        try model.save(company, expected: nil, apply: {})
        XCTAssertEqual(CompanyAccess(root: root).active, company)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("company-access.json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var changed = company; changed.name = "Edited"
        XCTAssertThrowsError(try model.save(changed, expected: nil, apply: {}))
        XCTAssertThrowsError(try model.save(changed, expected: company, apply: { throw LeapinError.timeout }))
        XCTAssertEqual(model.active, company)
        XCTAssertEqual(try CompanyAccessConfiguration.load(root: root).active, company)
        try model.activate(nil, apply: {})
        XCTAssertNil(model.active)
        try model.remove(company.id, apply: {})
        XCTAssertTrue(model.configuration.companies.isEmpty)
    }
    func testTemplatesExcludeMachineBindingsAndNeverActivateAnything() throws {
        var company = try connection(method: .systemVPN)
        company.application = URL(fileURLWithPath: "/Applications/Fixture Company.app")
        company.vpnServiceID = UUID()
        let data = try CompanyAccessTemplate(company).data()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("/Applications")); XCTAssertFalse(text.contains(company.vpnServiceID!.uuidString))
        let imported = try CompanyAccessTemplate.decode(data).draft()
        XCTAssertNil(imported.application); XCTAssertNil(imported.vpnServiceID)
        XCTAssertNotEqual(imported.id, company.id)
        XCTAssertEqual(imported.resources.first?.url, company.resources.first?.url)
        XCTAssertThrowsError(try imported.validate(), "Local VPN binding must be explicitly selected")
        XCTAssertThrowsError(try CompanyAccessTemplate.decode(Data("{\"version\":99}".utf8)))
    }
    @MainActor
    func testDirectChecksUseOriginOnlyAndDoNotTreatLoginAsSuccess() async throws {
        let model = CompanyAccess(root: try root(), resolver: CompanyTestResolver(["10.0.0.2"]), tcp: { _, _ in }, web: { url, port, systemDefault in
            XCTAssertEqual(url.absoluteString, "https://git.corp.fixture/"); XCTAssertNil(port); XCTAssertFalse(systemDefault)
            return HTTPProbeResult(url: url.absoluteString, statusCode: 401)
        })
        let company = try connection(); try model.save(company, expected: nil, apply: {})
        await model.check(company.resources[0], proxyPort: nil)
        let report = try XCTUnwrap(model.reports[company.resources[0].id])
        XCTAssertTrue(report.hasProblem)
        XCTAssertTrue(report.steps.contains(where: { $0.id == "dns" }))
        XCTAssertTrue(report.steps.contains(where: { $0.detail.contains("身份") }))
    }
    @MainActor
    func testProxyCheckResolvesOnlyProxyAndDoesNotMisreportUnauthenticatedRoute() async throws {
        let resolver = CompanyTestResolver(["10.0.0.9"])
        let model = CompanyAccess(root: try root(), resolver: resolver, tcp: { _, _ in }, web: { _, port, _ in
            XCTAssertEqual(port, 18990)
            return HTTPProbeResult(url: "https://git.corp.fixture/", statusCode: 407)
        })
        var company = try connection(method: .httpProxy); company.proxy = URL(string: "http://proxy.corp.fixture:8080")
        try model.save(company, expected: nil, apply: {})
        await model.check(company.resources[0], proxyPort: 18990)
        let asks = await resolver.asked
        XCTAssertEqual(asks, ["proxy.corp.fixture"])
        XCTAssertTrue(model.reports[company.resources[0].id]?.hasProblem == true)
    }
    @MainActor
    func testCancelledAndStaleChecksCannotOverwriteNewConfiguration() async throws {
        let model = CompanyAccess(root: try root(), resolver: CompanyTestResolver(["10.0.0.2"]), tcp: { _, _ in
            try await Task.sleep(nanoseconds: 100_000_000)
        }, web: { url, _, _ in HTTPProbeResult(url: url.absoluteString, statusCode: 200) })
        let company = try connection(); try model.save(company, expected: nil, apply: {})
        let task = Task { await model.check(company.resources[0], proxyPort: nil) }
        try await Task.sleep(nanoseconds: 20_000_000)
        model.cancelCheck(); await task.value
        XCTAssertTrue(model.reports.isEmpty); XCTAssertNil(model.checking)
        await model.check(company.resources[0], proxyPort: nil, contextValid: { false })
        XCTAssertTrue(model.reports.isEmpty)
        XCTAssertTrue(model.message?.contains("发生变化") == true)
    }
}
