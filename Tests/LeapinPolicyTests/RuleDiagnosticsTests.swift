import XCTest
import Foundation
@testable import LeapinPolicy
import LeapinCore

/// P3 diagnostics tests: the editor must be able to say "this rule never fires"
/// without ever producing a false alarm. Each test keeps the rule list small and
/// readable so the reasoning behind a verdict is obvious.
final class RuleDiagnosticsTests: XCTestCase {

    // MARK: - Helpers

    private func r(_ line: String) throws -> Rule {
        try RuleParser.parse(line: line)
    }

    /// A rule built directly, bypassing parser validation. Diagnostics must stay
    /// honest even for rules that came from an importer or a hand-written model.
    private func rawRule(_ kind: RuleKind, _ value: String, _ policy: String = "PROXY",
                         negate: Bool = false, modifiers: [String] = []) -> Rule {
        Rule(kind: kind, value: value, policy: policy, modifiers: modifiers,
             negate: negate, raw: "")
    }

    private func engine(_ rules: [Rule], sets: [String: [Rule]] = [:]) -> RuleEngine {
        let profile = Profile(name: "diag", outbounds: [.direct, .reject, proxy("PROXY")],
                              groups: [], rules: rules)
        return RuleEngine(profile: profile, ruleSets: sets)
    }

    private func proxy(_ name: String) -> OutboundConfig {
        OutboundConfig(name: name, type: .http, host: "127.0.0.1", port: 8080)
    }

    // MARK: - duplicate

    func testDuplicateFlagsLaterRuleAndPointsAtFirst() throws {
        let rules = try [
            r("DOMAIN,example.com,PROXY"),
            r("DOMAIN,example.com,PROXY"),
        ]
        let out = engine(rules).diagnostics()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].index, 1)
        XCTAssertEqual(out[0].kind, .duplicate)
        XCTAssertEqual(out[0].shadowedByIndex, 0)
        XCTAssertEqual(out[0].ruleID, rules[1].id)
    }

    // MARK: - shadowed

    func testSuffixParentShadowsSubdomainAndExactDomain() throws {
        let rules = try [
            r("DOMAIN-SUFFIX,example.com,PROXY"),
            r("DOMAIN-SUFFIX,api.example.com,DIRECT"),
            r("DOMAIN,api.example.com,REJECT"),
        ]
        let out = engine(rules).diagnostics()
        XCTAssertEqual(out.map(\.index), [1, 2])
        XCTAssertEqual(out.map(\.kind), [.shadowed, .shadowed])
        XCTAssertEqual(out.map(\.shadowedByIndex), [0, 0])
    }

    func testReversedSuffixOrderIsNotShadowed() throws {
        // A subdomain suffix does not cover its parent.
        let rules = try [
            r("DOMAIN-SUFFIX,api.example.com,DIRECT"),
            r("DOMAIN-SUFFIX,example.com,PROXY"),
        ]
        XCTAssertTrue(engine(rules).diagnostics().isEmpty)
    }

    func testExactDomainThenSuffixIsNotShadowed() throws {
        // DOMAIN,example.com only matches example.com itself, not subdomains, so
        // the later suffix rule still has work to do.
        let rules = try [
            r("DOMAIN,example.com,PROXY"),
            r("DOMAIN-SUFFIX,example.com,DIRECT"),
        ]
        XCTAssertTrue(engine(rules).diagnostics().isEmpty)
    }

    func testSameMatcherDifferentPolicyIsShadowed() throws {
        let rules = try [
            r("DOMAIN-KEYWORD,tracker,PROXY"),
            r("DOMAIN-KEYWORD,tracker,REJECT"),
        ]
        let out = engine(rules).diagnostics()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].kind, .shadowed)
        XCTAssertEqual(out[0].shadowedByIndex, 0)
    }

    func testCIDRCoverageIsShadowed() throws {
        let rules = try [
            r("IP-CIDR,10.0.0.0/8,PROXY"),
            r("IP-CIDR,10.1.0.0/16,REJECT"),
            r("IP-CIDR,192.168.0.0/16,DIRECT"),
        ]
        let out = engine(rules).diagnostics()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].index, 1)
        XCTAssertEqual(out[0].kind, .shadowed)
        XCTAssertEqual(out[0].shadowedByIndex, 0)
    }

    func testSmallerCIDRBeforeLargerIsNotShadowed() throws {
        let rules = try [
            r("IP-CIDR,10.1.0.0/16,REJECT"),
            r("IP-CIDR,10.0.0.0/8,PROXY"),
        ]
        XCTAssertTrue(engine(rules).diagnostics().isEmpty)
    }

    func testSourceAndDestinationCIDRTreesDoNotShadowEachOther() throws {
        let rules = try [
            r("SRC-IP-CIDR,10.0.0.0/8,PROXY"),
            r("IP-CIDR,10.0.0.0/8,REJECT"),
        ]
        XCTAssertTrue(engine(rules).diagnostics().isEmpty)
    }

    // MARK: - unreachable

    func testRulesAfterFinalAreUnreachable() throws {
        let rules = try [
            r("MATCH,DIRECT"),
            r("DOMAIN,example.com,PROXY"),
            r("IP-CIDR,10.0.0.0/8,REJECT"),
        ]
        let out = engine(rules).diagnostics()
        XCTAssertEqual(out.map(\.index), [1, 2])
        XCTAssertEqual(out.map(\.kind), [.unreachable, .unreachable])
        XCTAssertEqual(out.map(\.shadowedByIndex), [0, 0])
        XCTAssertTrue(out[0].reason.contains("FINAL"))
    }

    func testNegatedFinalDoesNotStopEvaluation() throws {
        // "!MATCH" evaluates true then flips to false, so it never fires and the
        // rule after it is still reachable.
        let rules = [
            rawRule(.match, "", "DIRECT", negate: true),
            rawRule(.domain, "example.com", "PROXY"),
        ]
        XCTAssertTrue(engine(rules).diagnostics().isEmpty)
    }

    // MARK: - never-match

    func testEmptyValueAndInvalidMatchersAreNeverMatch() {
        let rules = [
            rawRule(.domain, ""),
            rawRule(.ipCIDR, "999.1.1.1/8"),
            rawRule(.domainRegex, "["),
            rawRule(.or, ""),
            rawRule(.ruleSet, ""),
        ]
        let out = engine(rules).diagnostics()
        XCTAssertEqual(out.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertTrue(out.allSatisfy { $0.kind == .neverMatch })
    }

    // MARK: - rule-set-missing

    func testMissingRuleSetIsReported() throws {
        let rules = try [
            r("RULE-SET,ads,PROXY"),
            r("RULE-SET,ghost,REJECT"),
            r("MATCH,DIRECT"),
        ]
        let loaded = try [r("DOMAIN-SUFFIX,ads.example,REJECT")]
        let out = engine(rules, sets: ["ads": loaded]).diagnostics()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].index, 1)
        XCTAssertEqual(out[0].kind, .ruleSetMissing)
        XCTAssertNil(out[0].shadowedByIndex)
    }

    // MARK: - conservative behaviour

    func testNegatedEarlierRuleDoesNotShadowLaterRule() throws {
        let rules = try [
            r("!DOMAIN-SUFFIX,example.com,REJECT"),
            r("DOMAIN-SUFFIX,example.com,PROXY"),
        ]
        XCTAssertTrue(engine(rules).diagnostics().isEmpty)
    }

    func testBooleanRuleNeverShadows() throws {
        let rules = try [
            r("AND,((DOMAIN,a.com),(DOMAIN-SUFFIX,a.com)),PROXY"),
            r("DOMAIN,a.com,DIRECT"),
        ]
        XCTAssertTrue(engine(rules).diagnostics().isEmpty)
    }

    // MARK: - shape

    func testDiagnosticsAreAscendingAndNoArgMatchesExplicitRules() throws {
        let rules = try [
            r("DOMAIN,dup.test,PROXY"),
            r("DOMAIN,dup.test,PROXY"),
            r("MATCH,DIRECT"),
            r("DOMAIN,late.test,PROXY"),
        ]
        let engine = engine(rules)
        let implicit = engine.diagnostics()
        let explicit = engine.diagnostics(rules)
        XCTAssertEqual(implicit.map(\.index), [1, 3])
        XCTAssertEqual(implicit.map(\.index), implicit.map(\.index).sorted())
        XCTAssertEqual(implicit.map(\.index), explicit.map(\.index))
        XCTAssertEqual(implicit.map(\.kind), explicit.map(\.kind))
        // raw and ruleID must be usable by the editor directly.
        XCTAssertFalse(implicit[0].raw.isEmpty)
        XCTAssertEqual(implicit[0].raw, rules[1].raw)
    }
}
