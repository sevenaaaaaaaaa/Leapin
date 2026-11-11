import XCTest
import LeapinCore
@testable import LeapinRuntime

final class EcosystemPlanTests: XCTestCase {
    func testSharePlanLimitsOriginAndRequiresExplicitAudience() throws {
        for input in ["https://example.com:443", "http://127.0.0.1", "http://name:pass@localhost:3000", "http://localhost:3000/admin", "http://localhost:3000/?token=secret", "http://localhost:0", "ftp://localhost:3000"] {
            XCTAssertThrowsError(try ServiceSharePlan(origin: input, minutes: 30, email: "", publicAccess: true), input)
        }
        XCTAssertThrowsError(try ServiceSharePlan(origin: "http://localhost:3000", minutes: 30, email: "", publicAccess: false))
        let plan = try ServiceSharePlan(origin: "http://localhost:3000", minutes: 30, email: "dev@example.com", publicAccess: false)
        XCTAssertThrowsError(try plan.arguments(emailSupported: false))
        XCTAssertTrue(try plan.arguments(emailSupported: true).contains("--allowed-mail"))
        XCTAssertEqual(plan.email, "dev@example.com")
    }
    func testShareURLAcceptsOnlyExactTrycloudflareHost() throws {
        XCTAssertEqual(ServiceSharePlan.generatedURL("url https://my-test-service.trycloudflare.com\nRegistered tunnel connection")?.host, "my-test-service.trycloudflare.com")
        XCTAssertNil(ServiceSharePlan.generatedURL("https://evil.example"))
        XCTAssertNil(ServiceSharePlan.generatedURL("https://my-test.trycloudflare.com.attacker.example"))
    }
    func testDebugPlanScopesHostAndPreservesTLSVerification() throws {
        let plan = try DebugChannelPlan(host: "https://example.com/path?token=private", upstreamPort: 18080)
        let args = plan.arguments(port: 18081, directory: URL(fileURLWithPath: "/tmp/debug directory"))
        XCTAssertTrue(args.contains("^example\\.com(:[0-9]+)?$"))
        XCTAssertTrue(args.contains("ssl_insecure=false"))
        XCTAssertTrue(args.contains("upstream:http://127.0.0.1:18080"))
        XCTAssertFalse(args.joined().contains("private"))
        XCTAssertFalse(DebugChannelPlan.addon.contains("request.url"))
        XCTAssertFalse(DebugChannelPlan.addon.contains("request.headers"))
        XCTAssertThrowsError(try DebugChannelPlan(host: "example.com", upstreamPort: 0))
    }
    func testTUNExportIsPrivateAndSafelyQuotesPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leapin-tun-'\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try TUNLaunchPlan(source: "rules: [MATCH,DIRECT]")
        let script = try plan.export(to: root, cli: URL(fileURLWithPath: "/tmp/a'b/leapin"), kernel: URL(fileURLWithPath: "/tmp/mihomo"))
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("'\\''"))
        let source = root.appendingPathComponent("source.yaml")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
    @MainActor
    func testTUNCannotElevateWithoutUserAction() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Only applicable without root") }
        let session = ManagedTUNSession()
        do { try await session.start(source: "rules: [MATCH,DIRECT]"); XCTFail("must require administrator") } catch {}
        XCTAssertFalse(session.kernel.running)
    }
}
