import XCTest
@testable import LeapinControl
import LeapinCore

final class ControlContractTests: XCTestCase {
    func testStatusRoundTripsThroughJSON() throws {
        let status = ControlStatus(engineState: "running", mixedPort: 7890, httpPort: 7891,
                                   socksPort: 7892, controlPort: 7900, ruleCount: 7,
                                   adblockRuleCount: 3, activeConnections: 2,
                                   systemProxyActive: false, uptimeSeconds: 12.5)
        let data = try JSONEncoder().encode(status)
        let back = try JSONDecoder().decode(ControlStatus.self, from: data)
        XCTAssertEqual(back, status)
    }

    func testExplainCarriesTraceAndDiagnostics() throws {
        let diag = RuleDiagnostic(ruleID: "1", raw: "DOMAIN-SUFFIX,example.com,DIRECT", index: 1,
                                  kind: .shadowed, reason: "被 #0 覆盖", shadowedByIndex: 0)
        let result = ControlExplainResult(host: "a.example.com", port: 443, policy: "DIRECT",
                                          matchedRule: "DOMAIN-SUFFIX,example.com,DIRECT",
                                          trace: ["✓ #0"], diagnostics: [diag])
        let back = try JSONDecoder().decode(ControlExplainResult.self,
                                            from: try JSONEncoder().encode(result))
        XCTAssertEqual(back.trace.count, 1)
        XCTAssertEqual(back.diagnostics.first?.kind, .shadowed)
    }

    func testNodeRoundTripsThroughJSON() throws {
        let node = ControlNode(name: "HK-01", type: "trojan", server: "hk.example.com", port: 443,
                               dialable: true, groups: ["Proxy", "Auto"], latencyMs: 87,
                               checkedAtMs: 1_700_000_000_000, consecutiveFailures: 0)
        let back = try JSONDecoder().decode(ControlNode.self, from: try JSONEncoder().encode(node))
        XCTAssertEqual(back, node)

        // A never-tested node: both observation fields stay nil through the round trip.
        let fresh = ControlNode(name: "JP-01", type: "vmess", server: "jp.example.com", port: 80,
                                dialable: true, groups: [])
        let freshBack = try JSONDecoder().decode(ControlNode.self,
                                                 from: try JSONEncoder().encode(fresh))
        XCTAssertNil(freshBack.latencyMs)
        XCTAssertNil(freshBack.checkedAtMs)
        XCTAssertNil(freshBack.lastError)
    }

    func testNodeTestResultRoundTripsThroughJSON() throws {
        let result = ControlNodeTestResult(name: "HK-01", latencyMs: nil, error: "timeout",
                                           checkedAtMs: 1_700_000_001_000)
        let back = try JSONDecoder().decode(ControlNodeTestResult.self,
                                            from: try JSONEncoder().encode(result))
        XCTAssertEqual(back, result)
        XCTAssertNil(back.latencyMs)
        XCTAssertEqual(back.error, "timeout")
    }

    func testNodeSpeedResultRoundTripsThroughJSON() throws {
        let result = ControlNodeSpeedResult(name: "HK-01", url: "http://x/100mb",
                                            bytes: 10_000_000, elapsedMs: 3_200, mbps: 25.0,
                                            checkedAtMs: 1_700_000_002_000)
        let back = try JSONDecoder().decode(ControlNodeSpeedResult.self,
                                            from: try JSONEncoder().encode(result))
        XCTAssertEqual(back, result)
        XCTAssertNil(back.error)
    }

    func testControlErrorStatusCodes() {
        XCTAssertEqual(ControlError.unauthorized.statusCode, 401)
        XCTAssertEqual(ControlError.badRequest("x").statusCode, 400)
        XCTAssertEqual(ControlError.notFound("x").statusCode, 404)
    }
}
