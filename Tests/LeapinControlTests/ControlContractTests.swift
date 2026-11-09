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

    func testControlErrorStatusCodes() {
        XCTAssertEqual(ControlError.unauthorized.statusCode, 401)
        XCTAssertEqual(ControlError.badRequest("x").statusCode, 400)
        XCTAssertEqual(ControlError.notFound("x").statusCode, 404)
    }
}
