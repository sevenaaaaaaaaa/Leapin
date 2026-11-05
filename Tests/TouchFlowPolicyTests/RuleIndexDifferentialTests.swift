import XCTest
import Foundation
@testable import TouchFlowPolicy
import TouchFlowCore

/// P3 differential tests: the indexed engine must agree with the original linear
/// scan on every decision, chain and trace. The linear path is kept reachable via
/// RuleEngine(profile:ruleSets:geoIP:useIndex:false), which is exactly the code
/// the index replaced, so it works as a reference oracle.
final class RuleIndexDifferentialTests: XCTestCase {

    // MARK: - Deterministic RNG

    /// SplitMix64: tiny, seedable, and stable across platforms so a failure is
    /// always reproducible from the printed seed.
    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { self.state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }

        mutating func pick<T>(_ values: [T]) -> T { values[int(values.count)] }

        mutating func chance(_ percent: Int) -> Bool { int(100) < percent }
    }

    // MARK: - Generators

    private let domainPool = [
        "example.com", "api.example.com", "cdn.example.com", "ads.example.com",
        "test.org", "shop.test.org", "a.b.test.org", "weird.co.uk", "x.weird.co.uk",
        "localhost", "ads.net", "tracker.ads.net", "中文.example", "sub.中文.example",
    ]
    private let keywordPool = ["ads", "track", "api", "cdn", "广告", "test"]
    private let ipv4Pool = [
        "10.1.2.3", "10.200.1.1", "192.168.1.10", "1.2.3.4", "8.8.8.8", "172.16.5.5",
    ]
    private let cidrPool = [
        "10.0.0.0/8", "10.1.0.0/16", "10.1.2.0/24", "192.168.0.0/16", "0.0.0.0/0",
        "1.2.3.0/24", "172.16.0.0/12",
    ]
    private let cidr6Pool = ["2001:db8::/32", "2001:db8:1::/48", "::/0", "fe80::/10"]
    private let ipv6Pool = ["2001:db8:1::5", "2001:db8:1:2::9", "fe80::1", "::1"]
    private let processPool = ["WeChat", "Safari", "com.apple.Safari", "Chrome"]
    private let policies = ["PROXY", "DIRECT", "REJECT", "AUTO", ""]

    private func policy(_ rng: inout SeededRNG) -> String { rng.pick(policies) }

    /// One random rule line. keep it parseable: RuleParser is the real front door.
    private func randomLine(_ rng: inout SeededRNG, depth: Int) -> String {
        var negate = rng.chance(15) ? "!" : ""
        // Do not negate boolean expressions: the syntax gets ambiguous and the
        // linear reference would not be more trustworthy than the index.
        let kind = rng.int(depth > 0 ? 8 : 13)
        switch kind {
        case 0:
            return "\(negate)DOMAIN,\(rng.pick(domainPool)),\(policy(&rng))"
        case 1:
            return "\(negate)DOMAIN-SUFFIX,\(rng.pick(domainPool)),\(policy(&rng))"
        case 2:
            return "\(negate)DOMAIN-KEYWORD,\(rng.pick(keywordPool)),\(policy(&rng))"
        case 3:
            return "\(negate)IP-CIDR,\(rng.pick(cidrPool)),\(policy(&rng))"
        case 4:
            return "\(negate)IP-CIDR6,\(rng.pick(cidr6Pool)),\(policy(&rng))"
        case 5:
            return "\(negate)SRC-IP-CIDR,\(rng.pick(cidrPool)),\(policy(&rng))"
        case 6:
            return "\(negate)PROCESS-NAME,\(rng.pick(processPool)),\(policy(&rng))"
        case 7:
            return "\(negate)GEOIP,\(rng.pick(["CN", "US", "JP"])),\(policy(&rng))"
        case 8:
            negate = ""
            return "AND,((DOMAIN,\(rng.pick(domainPool))),(DOMAIN-SUFFIX,\(rng.pick(domainPool)))),\(policy(&rng))"
        case 9:
            negate = ""
            return "OR,((PROCESS-NAME,\(rng.pick(processPool))),(DOMAIN-KEYWORD,\(rng.pick(keywordPool)))),\(policy(&rng))"
        case 10:
            negate = ""
            return "NOT,((DOMAIN,\(rng.pick(domainPool)))),\(policy(&rng))"
        case 11:
            negate = ""
            let set = rng.pick(["ads", "ads", "ghost", "nested"])
            return "RULE-SET,\(set),\(policy(&rng))"
        default:
            negate = ""
            return "MATCH,\(policy(&rng))"
        }
    }

    private func randomRules(_ rng: inout SeededRNG, count: Int) -> [Rule] {
        var rules: [Rule] = []
        for _ in 0..<count {
            let line = randomLine(&rng, depth: 0)
            if let rule = try? RuleParser.parse(line: line) {
                rules.append(rule)
            }
        }
        return rules
    }

    private func randomMeta(_ rng: inout SeededRNG) -> ConnectionMeta {
        let host: String
        if rng.chance(20) {
            host = rng.pick(["example.com", "API.EXAMPLE.COM", "a.b.test.org.", "example.com:443"])
        } else if rng.chance(10) {
            host = "\(rng.pick(["x", "y", "tracker", "cdn"])).\(rng.pick(domainPool))"
        } else {
            host = rng.pick(domainPool)
        }
        return ConnectionMeta(
            host: host,
            port: 443,
            network: "tcp",
            sourceApp: rng.chance(50) ? rng.pick(processPool) : nil,
            destinationIP: rng.chance(70) ? rng.pick(ipv4Pool + ipv6Pool) : nil,
            sourceIP: rng.chance(40) ? rng.pick(ipv4Pool) : nil
        )
    }

    private func makeProfile(_ rules: [Rule]) -> Profile {
        Profile(name: "diff", outbounds: [.direct, .reject, proxy("PROXY"), proxy("AUTO")],
                groups: [], rules: rules)
    }

    private func proxy(_ name: String) -> OutboundConfig {
        OutboundConfig(name: name, type: .http, host: "127.0.0.1", port: 8080)
    }

    // MARK: - Randomised differential sweep

    func testRandomRuleSetsMatchLinearReference() throws {
        var rng = SeededRNG(seed: 0x5EED_1234_ABCD_0001)
        var comparisons = 0

        for round in 0..<320 {
            let profileRules = randomRules(&rng, count: 3 + rng.int(18))

            // Two level rule-sets: "ads" and "nested" are loaded, "ghost" is not.
            var sets: [String: [Rule]] = [:]
            sets["ads"] = randomRules(&rng, count: 2 + rng.int(6))
            sets["nested"] = randomRules(&rng, count: 1 + rng.int(4))
            if rng.chance(30) {
                // Make ads reference nested through the normal syntax.
                if let setRule = try? RuleParser.parse(line: "RULE-SET,nested,PROXY") {
                    sets["ads"]?.append(setRule)
                }
            }

            let indexed = RuleEngine(profile: makeProfile(profileRules), ruleSets: sets)
            let linear = RuleEngine(profile: makeProfile(profileRules), ruleSets: sets,
                                    geoIP: nil, useIndex: false)

            for _ in 0..<12 {
                let meta = randomMeta(&rng)
                let a = indexed.decide(meta)
                let b = linear.decide(meta)
                comparisons += 1

                XCTAssertEqual(a.policy, b.policy,
                               "round \(round) policy mismatch for \(meta.host) ip=\(meta.destinationIP ?? "-")")
                XCTAssertEqual(a.outbound.name, b.outbound.name, "round \(round) outbound mismatch")
                XCTAssertEqual(a.matchedRule, b.matchedRule, "round \(round) matchedRule mismatch")
                XCTAssertEqual(a.chain?.index, b.chain?.index, "round \(round) chain index mismatch")
                XCTAssertEqual(a.chain?.isFinal, b.chain?.isFinal, "round \(round) chain isFinal mismatch")
                XCTAssertEqual(a.chain?.steps.map(\.label), b.chain?.steps.map(\.label),
                               "round \(round) chain labels mismatch for host \(meta.host)")
                XCTAssertEqual(a.chain?.steps.map(\.detail), b.chain?.steps.map(\.detail),
                               "round \(round) chain details mismatch for host \(meta.host)")

                let ea = indexed.explain(meta)
                let eb = linear.explain(meta)
                XCTAssertEqual(ea.trace, eb.trace, "round \(round) explain trace mismatch for \(meta.host)")
            }
        }

        XCTAssertGreaterThan(comparisons, 3000)
    }

    // MARK: - Boundaries

    func testLongestSuffixWinsByOrder() throws {
        let rules = try [
            r("DOMAIN-SUFFIX,com,REJECT"),
            r("DOMAIN-SUFFIX,example.com,PROXY"),
            r("DOMAIN-SUFFIX,api.example.com,DIRECT"),
            r("MATCH,DIRECT"),
        ]
        let engine = RuleEngine(profile: makeProfile(rules))
        let index = RuleIndex(rules: rules)

        XCTAssertEqual(engine.decide(meta("api.example.com")).matchedRule,
                       "DOMAIN-SUFFIX,com,REJECT")
        XCTAssertEqual(engine.decide(meta("other.com")).outbound.name, "REJECT")
        XCTAssertEqual(engine.decide(meta("api.example.com")).outbound.name, "REJECT")

        // Every suffix node must be a candidate, ascending and de-duplicated.
        XCTAssertEqual(index.candidates(for: meta("api.example.com")), [0, 1, 2, 3])
        XCTAssertEqual(index.candidates(for: meta("nomatch.net")), [3])
    }

    func testOverlappingCIDRTreesReturnAllCoveringPrefixes() throws {
        let rules = try [
            r("IP-CIDR,10.0.0.0/8,REJECT"),
            r("IP-CIDR,10.1.0.0/16,PROXY"),
            r("IP-CIDR,10.1.2.0/24,DIRECT"),
            r("MATCH,DIRECT"),
        ]
        let index = RuleIndex(rules: rules)
        var meta = meta("10.1.2.9")
        meta = ConnectionMeta(host: "10.1.2.9", port: 443, network: "tcp",
                              destinationIP: "10.1.2.9")
        XCTAssertEqual(index.candidates(for: meta), [0, 1, 2, 3])

        let engine = RuleEngine(profile: makeProfile(rules))
        XCTAssertEqual(engine.decide(meta).outbound.name, "REJECT", "first matching prefix wins")

        let high = ConnectionMeta(host: "10.9.9.9", port: 443, network: "tcp",
                                  destinationIP: "10.9.9.9")
        XCTAssertEqual(RuleIndex(rules: rules).candidates(for: high), [0, 3])
    }

    func testNegatedRuleFallsThroughAndFirstMatchWins() throws {
        let rules = try [
            r("!DOMAIN-SUFFIX,example.com,REJECT"),
            r("DOMAIN-SUFFIX,example.com,PROXY"),
            r("MATCH,DIRECT"),
        ]
        let engine = RuleEngine(profile: makeProfile(rules))
        let linear = RuleEngine(profile: makeProfile(rules), ruleSets: [:], geoIP: nil, useIndex: false)

        // Inside example.com the negated rule fails, so the second rule wins.
        XCTAssertEqual(engine.decide(meta("www.example.com")).outbound.name, "PROXY")
        // Outside, the negated rule matches everything.
        XCTAssertEqual(engine.decide(meta("other.test")).outbound.name, "REJECT")
        XCTAssertEqual(engine.explain(meta("www.example.com")).trace,
                       linear.explain(meta("www.example.com")).trace)
    }

    func testSourceIPCidrIsIndependentFromDestinationTree() throws {
        let rules = try [
            r("SRC-IP-CIDR,10.0.0.0/8,REJECT"),
            r("IP-CIDR,10.0.0.0/8,PROXY"),
            r("MATCH,DIRECT"),
        ]
        let index = RuleIndex(rules: rules)
        let srcOnly = ConnectionMeta(host: "example.com", port: 443, network: "tcp",
                                     sourceIP: "10.4.5.6")
        let dstOnly = ConnectionMeta(host: "example.com", port: 443, network: "tcp",
                                     destinationIP: "10.4.5.6")
        XCTAssertEqual(index.candidates(for: srcOnly), [0, 2])
        XCTAssertEqual(index.candidates(for: dstOnly), [1, 2])

        let engine = RuleEngine(profile: makeProfile(rules))
        XCTAssertEqual(engine.decide(srcOnly).outbound.name, "REJECT")
        XCTAssertEqual(engine.decide(dstOnly).outbound.name, "PROXY")
    }

    func testKeywordAhoCorasickHandlesUnicodeAndOverlap() throws {
        let rules = try [
            r("DOMAIN-KEYWORD,广告,REJECT"),
            r("DOMAIN-KEYWORD,ads,PROXY"),
            r("DOMAIN-KEYWORD,tracker,PROXY"),
            r("MATCH,DIRECT"),
        ]
        let index = RuleIndex(rules: rules)
        XCTAssertEqual(index.candidates(for: meta("x.广告.example")), [0, 3])
        XCTAssertEqual(index.candidates(for: meta("my-ads-tracker.test")), [1, 2, 3])

        let engine = RuleEngine(profile: makeProfile(rules))
        XCTAssertEqual(engine.decide(meta("my-ads-tracker.test")).outbound.name, "PROXY")
        XCTAssertEqual(engine.decide(meta("x.广告.example")).outbound.name, "REJECT")
    }

    func testRuleSetMemberOrderAndNestedSetChain() throws {
        let outer = try r("RULE-SET,ads,REJECT")
        let match = try r("MATCH,DIRECT")
        let ads = try [
            r("DOMAIN-SUFFIX,first.example,PROXY"),
            r("RULE-SET,nested,PROXY"),
            r("DOMAIN-SUFFIX,second.example,PROXY"),
        ]
        let nested = try [r("PROCESS-NAME,WeChat,DIRECT")]
        let sets = ["ads": ads, "nested": nested]
        let engine = RuleEngine(profile: makeProfile([outer, match]), ruleSets: sets)
        let linear = RuleEngine(profile: makeProfile([outer, match]), ruleSets: sets,
                                geoIP: nil, useIndex: false)

        let byNested = ConnectionMeta(host: "nested.example", port: 443, network: "tcp",
                                      sourceApp: "WeChat")
        let a = engine.decide(byNested)
        let b = linear.decide(byNested)
        XCTAssertEqual(a.policy, b.policy)
        XCTAssertEqual(a.chain?.steps.map(\.label), b.chain?.steps.map(\.label))
        XCTAssertEqual(a.chain?.steps.count, 3, "outer rule + nested set member + process member")
    }

    func testCandidatesAreAscendingUniqueAndSuperset() throws {
        var rng = SeededRNG(seed: 0xC0FF_EE00_1234_5678)
        for _ in 0..<80 {
            let rules = randomRules(&rng, count: 5 + rng.int(25))
            let index = RuleIndex(rules: rules)
            for _ in 0..<8 {
                let meta = randomMeta(&rng)
                let candidates = index.candidates(for: meta)
                XCTAssertEqual(candidates, candidates.sorted(), "candidates must be ascending")
                XCTAssertEqual(candidates.count, Set(candidates).count, "candidates must be unique")

                let engine = RuleEngine(profile: makeProfile(rules))
                let linear = RuleEngine(profile: makeProfile(rules), ruleSets: [:], geoIP: nil,
                                        useIndex: false)
                XCTAssertEqual(engine.decide(meta).policy, linear.decide(meta).policy)
            }
        }
    }

    private func r(_ line: String) throws -> Rule {
        try RuleParser.parse(line: line)
    }

    private func meta(_ host: String) -> ConnectionMeta {
        ConnectionMeta(host: host, port: 443, network: "tcp")
    }
}
