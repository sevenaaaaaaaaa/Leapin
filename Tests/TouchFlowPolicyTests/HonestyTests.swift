import XCTest
import Foundation
@testable import TouchFlowPolicy
import TouchFlowCore

/// P0 honesty tests: auto groups must follow measured health, SRC-IP must use the
/// real client address, rule chains must name the rule-set member that fired, and
/// imports must admit which protocols cannot be dialed yet.
final class HonestyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TFHealth.shared.reset()
    }

    override func tearDown() {
        TFHealth.shared.reset()
        super.tearDown()
    }

    private func outbound(_ name: String) -> OutboundConfig {
        OutboundConfig(name: name, type: .http, host: "127.0.0.1", port: 8080)
    }

    private func meta(_ host: String, sourceIP: String? = nil) -> ConnectionMeta {
        ConnectionMeta(host: host, port: 443, network: "tcp", sourceIP: sourceIP)
    }

    private func autoProfile(_ groupType: PolicyGroupType, tolerance: Int? = 50) -> Profile {
        let group = PolicyGroup(name: "AUTO", type: groupType, proxies: ["A", "B"], tolerance: tolerance)
        let rule = try! RuleParser.parse(line: "MATCH,AUTO")
        return Profile(name: "auto", outbounds: [.direct, .reject, outbound("A"), outbound("B")],
                       groups: [group], rules: [rule])
    }

    // MARK: url-test

    func testURLTestPicksFastestMeasuredMember() {
        TFHealth.shared.record(name: "A", latencyMs: 220)
        TFHealth.shared.record(name: "B", latencyMs: 40)
        let engine = RuleEngine(profile: autoProfile(.urlTest))
        XCTAssertEqual(engine.decide(meta("example.com")).outbound.name, "B")
    }

    func testURLTestKeepsWinnerWithinTolerance() {
        TFHealth.shared.record(name: "A", latencyMs: 220)
        TFHealth.shared.record(name: "B", latencyMs: 40)
        let engine = RuleEngine(profile: autoProfile(.urlTest, tolerance: 20))
        XCTAssertEqual(engine.decide(meta("one.test")).outbound.name, "B")

        // A becomes faster but only by 5 ms: flipping the whole machine for that
        // would be worse than staying put.
        TFHealth.shared.record(name: "A", latencyMs: 35)
        XCTAssertEqual(engine.decide(meta("two.test")).outbound.name, "B")

        // Now A is clearly ahead of the 20 ms tolerance, so the winner moves.
        TFHealth.shared.record(name: "A", latencyMs: 5)
        XCTAssertEqual(engine.decide(meta("three.test")).outbound.name, "A")
    }

    func testURLTestFallsBackToFirstBeforeAnyProbe() {
        let engine = RuleEngine(profile: autoProfile(.urlTest))
        XCTAssertEqual(engine.decide(meta("example.com")).outbound.name, "A")
    }

    // MARK: fallback

    func testFallbackSkipsDeadMember() {
        TFHealth.shared.record(name: "A", latencyMs: nil, error: "connection refused")
        TFHealth.shared.record(name: "B", latencyMs: 88)
        let engine = RuleEngine(profile: autoProfile(.fallback))
        XCTAssertEqual(engine.decide(meta("example.com")).outbound.name, "B")
    }

    func testFallbackKeepsFirstWhileItIsAlive() {
        TFHealth.shared.record(name: "A", latencyMs: 900)
        TFHealth.shared.record(name: "B", latencyMs: 20)
        let engine = RuleEngine(profile: autoProfile(.fallback))
        XCTAssertEqual(engine.decide(meta("example.com")).outbound.name, "A")
    }

    // MARK: SRC-IP

    func testSourceIPRuleUsesClientAddress() throws {
        let rules = [try RuleParser.parse(line: "SRC-IP-CIDR,10.0.0.0/8,DIRECT"),
                     try RuleParser.parse(line: "MATCH,REJECT")]
        let engine = RuleEngine(profile: Profile(name: "src", outbounds: [.direct, .reject], rules: rules))
        XCTAssertEqual(engine.decide(meta("example.com", sourceIP: "10.1.2.3")).policy, "DIRECT")
        XCTAssertEqual(engine.decide(meta("example.com", sourceIP: "192.0.2.9")).policy, "REJECT")
        XCTAssertEqual(engine.decide(meta("example.com")).policy, "REJECT")
    }

    // MARK: Rule chain

    func testChainNamesRuleAndMember() throws {
        let ruleSet = try RuleParser.parse(line: "DOMAIN-SUFFIX,ads.example,REJECT")
        let outer = try RuleParser.parse(line: "RULE-SET,ads,REJECT")
        let engine = RuleEngine(profile: Profile(name: "chain", outbounds: [.direct, .reject],
                                                 rules: [outer, try RuleParser.parse(line: "MATCH,DIRECT")]),
                                ruleSets: ["ads": [ruleSet]])
        let decision = engine.decide(meta("cdn.ads.example"))
        let chain = try XCTUnwrap(decision.chain)
        XCTAssertTrue(chain.summary.contains("RULE-SET"))
        XCTAssertTrue(chain.steps.contains { $0.label.contains("DOMAIN-SUFFIX,ads.example") })
        XCTAssertEqual(chain.policy, "REJECT")
    }

    func testChainMarksMatchAsFinal() throws {
        let engine = RuleEngine(profile: Profile(name: "final", outbounds: [.direct, .reject],
                                                 rules: [try RuleParser.parse(line: "MATCH,DIRECT")]))
        let chain = try XCTUnwrap(engine.decide(meta("example.com")).chain)
        XCTAssertTrue(chain.isFinal)
        XCTAssertEqual(chain.index, 1)
    }

    // MARK: Validate

    func testValidateFlagsUndialableProtocol() {
        let vmess = OutboundConfig(name: "vmess-1", type: .vmess, host: "1.2.3.4", port: 443,
                                   rawType: "vmess")
        let profile = Profile(name: "v", outbounds: [.direct, .reject, vmess],
                              rules: [])
        let issues = PolicyResolver(profile: profile).validate()
        XCTAssertTrue(issues.contains { $0.contains("vmess-1") && $0.contains("cannot be dialed") },
                      issues.joined(separator: " | "))
    }

    // MARK: Import honesty

    func testImportReportListsUndialableOutbounds() throws {
        let text = """
        mixed-port: 7890
        proxies:
          - name: vm-node
            type: vmess
            server: 1.2.3.4
            port: 443
            uuid: 11111111-1111-1111-1111-111111111111
        proxy-groups:
          - name: PROXY
            type: select
            proxies: [vm-node, DIRECT]
        rules:
          - MATCH,PROXY
        """
        let outcome = try ProfileImporter.importText(text, name: "测试", pathExtension: "yaml")
        XCTAssertTrue(outcome.report.notDialable.contains("vm-node"), "\(outcome.report.notDialable)")
        XCTAssertTrue(outcome.report.summary.contains("暂不可拨号"), outcome.report.summary)
        XCTAssertTrue(outcome.report.issues.contains { $0.item == "vmess" })
    }
}
