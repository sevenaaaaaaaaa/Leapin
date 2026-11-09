import XCTest
import Foundation
@testable import LeapinPolicy
import LeapinCore

final class PolicyTests: XCTestCase {

    // MARK: - Helpers

    private func r(_ line: String) throws -> Rule {
        try RuleParser.parse(line: line)
    }

    private func meta(_ host: String, ip: String? = nil, app: String? = nil) -> ConnectionMeta {
        ConnectionMeta(host: host, port: 443, network: "tcp", sourceApp: app,
                       destinationIP: ip)
    }

    private func profile(rules: [Rule], groups: [PolicyGroup] = [],
                         outbounds: [OutboundConfig] = [.direct, .reject]) -> Profile {
        Profile(name: "test", outbounds: outbounds, groups: groups, rules: rules)
    }

    private func proxy(_ name: String) -> OutboundConfig {
        OutboundConfig(name: name, type: .http, host: "127.0.0.1", port: 8080)
    }

    // MARK: 1. Surge syntax

    func testSurgeSyntaxParsing() throws {
        XCTAssertEqual(try r("DOMAIN,example.com,PROXY").kind, .domain)
        XCTAssertEqual(try r("DOMAIN,example.com,PROXY").value, "example.com")
        XCTAssertEqual(try r("DOMAIN,example.com,PROXY").policy, "PROXY")

        let suffix = try r("DOMAIN-SUFFIX,x,DIRECT,no-resolve")
        XCTAssertEqual(suffix.kind, .domainSuffix)
        XCTAssertTrue(suffix.noResolve)

        let cidr = try r("IP-CIDR,1.2.3.0/24,PROXY")
        XCTAssertEqual(cidr.kind, .ipCIDR)
        XCTAssertEqual(cidr.value, "1.2.3.0/24")

        XCTAssertEqual(try r("PROCESS-NAME,WeChat,DIRECT").value, "WeChat")
        XCTAssertEqual(try r("GEOIP,cn,DIRECT").value, "CN")
        XCTAssertEqual(try r("RULE-SET,ads,REJECT").kind, .ruleSet)

        let match = try r("MATCH,PROXY")
        XCTAssertEqual(match.kind, .match)
        XCTAssertEqual(match.policy, "PROXY")
        XCTAssertEqual(try r("FINAL,PROXY").kind, .match)

        XCTAssertEqual(try r("domain-suffix,ads.com,DIRECT  # inline comment").value, "ads.com")
        XCTAssertEqual(try r("- DOMAIN,yaml.test,PROXY").value, "yaml.test")

        let negated = try r("!DOMAIN,neg.test,REJECT")
        XCTAssertTrue(negated.negate)
        XCTAssertEqual(negated.kind, .domain)
    }

    // MARK: 2. Clash syntax / case insensitivity

    func testClashSyntaxAndCaseInsensitivity() throws {
        let text = """
        rules:
          - DOMAIN-SUFFIX,Clash.test,DIRECT
          - "IP-CIDR,10.0.0.0/8,PROXY,no-resolve"
          - MATCH,PROXY
        """
        let (rules, errors) = RuleParser.parseRules(text)
        XCTAssertTrue(errors.isEmpty, "unexpected errors: \(errors)")
        XCTAssertEqual(rules.count, 3)
        guard rules.count == 3 else { return XCTFail("expected 3 rules, got \(rules.count)") }
        XCTAssertEqual(rules[0].value, "clash.test")
        XCTAssertEqual(rules[1].kind, .ipCIDR)
        XCTAssertEqual(rules[2].kind, .match)

        let (parsed, errs) = RuleParser.parseRules("DOMAIN,a.com,DIRECT\nNONSENSE,b,c\nIP-CIDR,not-a-cidr,DIRECT")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(errs.count, 2)
    }

    // MARK: 3. AND / OR / NOT

    func testLogicalExpressions() throws {
        let and = try r("AND,((DOMAIN-SUFFIX,b.com),(DOMAIN-KEYWORD,api)),PROXY")
        XCTAssertEqual(and.kind, .and)
        XCTAssertEqual(and.value, "((DOMAIN-SUFFIX,b.com),(DOMAIN-KEYWORD,api))")

        let engine = RuleEngine(profile: profile(rules: [and]))
        XCTAssertEqual(engine.decide(meta("api.b.com")).policy, "PROXY")
        XCTAssertEqual(engine.decide(meta("x.b.com")).policy, "DIRECT")
        XCTAssertEqual(engine.decide(meta("api.a.com")).policy, "DIRECT")

        let or = try r("OR,((DOMAIN,a.com),(DOMAIN-SUFFIX,b.com)),PROXY")
        let orEngine = RuleEngine(profile: profile(rules: [or]))
        XCTAssertEqual(orEngine.decide(meta("a.com")).policy, "PROXY")
        XCTAssertEqual(orEngine.decide(meta("deep.b.com")).policy, "PROXY")
        XCTAssertEqual(orEngine.decide(meta("c.com")).policy, "DIRECT")

        let not = try r("NOT,((DOMAIN-SUFFIX,b.com)),PROXY")
        let notEngine = RuleEngine(profile: profile(rules: [not]))
        XCTAssertEqual(notEngine.decide(meta("b.com")).policy, "DIRECT")
        XCTAssertEqual(notEngine.decide(meta("other.com")).policy, "PROXY")

        let nested = try r("AND,((AND,((DOMAIN,a.com),(DOMAIN,b.com))),(DOMAIN-SUFFIX,c.com)),PROXY")
        XCTAssertEqual(nested.kind, .and)
        XCTAssertEqual(nested.value, "((AND,((DOMAIN,a.com),(DOMAIN,b.com))),(DOMAIN-SUFFIX,c.com))")
    }

    // MARK: 4. Order / first match / explain

    func testRuleOrderAndExplain() throws {
        let rules = [
            try r("DOMAIN-SUFFIX,blocked.test,REJECT"),
            try r("DOMAIN,exact.test,PROXY"),
            try r("MATCH,DIRECT"),
        ]
        let engine = RuleEngine(profile: profile(rules: rules))
        XCTAssertEqual(engine.ruleCount, 3)

        let rejected = engine.decide(meta("blocked.test"))
        XCTAssertEqual(rejected.policy, "REJECT")
        XCTAssertTrue(rejected.isBlocked)
        XCTAssertEqual(rejected.outbound.type, .reject)

        let explained = engine.explain(meta("blocked.test"))
        XCTAssertEqual(explained.policy, "REJECT")
        XCTAssertNotNil(explained.matchedRule)
        XCTAssertTrue(explained.trace.contains { $0.contains("matched rule #1") })
        XCTAssertTrue(explained.trace.first?.contains("host=blocked.test") == true)

        XCTAssertEqual(engine.decide(meta("exact.test")).policy, "PROXY")
        XCTAssertEqual(engine.decide(meta("unrelated.test")).policy, "DIRECT")
        XCTAssertEqual(engine.explain(meta("unrelated.test")).policy, "DIRECT")
    }

    // MARK: 5. CIDR v4/v6 + no-resolve

    func testCIDRAndNoResolve() throws {
        let rules = [
            try r("IP-CIDR,10.0.0.0/8,PROXY"),
            try r("IP-CIDR6,2001:db8::/32,PROXY"),
            try r("IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"),
            try r("MATCH,REJECT"),
        ]
        let engine = RuleEngine(profile: profile(rules: rules))

        XCTAssertEqual(engine.decide(meta("a.test", ip: "10.1.2.3")).policy, "PROXY")
        XCTAssertEqual(engine.decide(meta("a.test", ip: "11.1.2.3")).policy, "REJECT")
        XCTAssertEqual(engine.decide(meta("a.test", ip: "2001:db8::1")).policy, "PROXY")
        XCTAssertEqual(engine.decide(meta("a.test", ip: "2001:db9::1")).policy, "REJECT")
        XCTAssertEqual(engine.decide(meta("a.test", ip: "192.168.5.5")).policy, "DIRECT")

        let noResolve = RuleEngine(profile: profile(rules: [
            try r("IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"),
            try r("MATCH,PROXY"),
        ]))
        XCTAssertEqual(noResolve.decide(meta("router.local")).policy, "PROXY")
        XCTAssertEqual(noResolve.decide(meta("router.local", ip: "192.168.1.1")).policy, "DIRECT")

        let cidr = try XCTUnwrap(CIDR("1.2.3.0/24"))
        XCTAssertTrue(cidr.contains(address: "1.2.3.255"))
        XCTAssertFalse(cidr.contains(address: "1.2.4.0"))
    }

    // MARK: 6. PROCESS-NAME + GEOIP

    func testProcessNameAndGeoIP() throws {
        let engine = RuleEngine(profile: profile(rules: [
            try r("PROCESS-NAME,wechat,DIRECT"),
            try r("GEOIP,CN,DIRECT"),
            try r("MATCH,PROXY"),
        ]))
        XCTAssertEqual(engine.decide(meta("any.test", app: "WeChat")).policy, "DIRECT")
        XCTAssertEqual(engine.decide(meta("any.test", app: "/Applications/WeChat.app")).policy, "DIRECT")
        XCTAssertEqual(engine.decide(meta("any.test", app: "Safari")).policy, "PROXY")
        XCTAssertEqual(engine.decide(meta("cn.test", ip: "114.114.114.114")).policy, "DIRECT")
        XCTAssertEqual(engine.decide(meta("us.test", ip: "8.8.8.8")).policy, "PROXY")

        let geo = GeoIPDatabase()
        XCTAssertEqual(geo.country(of: "114.114.114.114"), "CN")
        XCTAssertEqual(geo.country(of: "8.8.8.8"), "US")
        XCTAssertEqual(geo.country(of: "192.168.1.10"), "PRIVATE")
        XCTAssertTrue(geo.contains("114.114.114.114", country: "CN"))
        XCTAssertFalse(geo.contains("114.114.114.114", country: "US"))
    }

    // MARK: 7. Policy groups

    func testPolicyGroupResolution() {
        let p1 = proxy("P1")
        let p2 = proxy("P2")
        let groups = [
            PolicyGroup(name: "SELECT", type: .select, proxies: ["P1", "P2"]),
            PolicyGroup(name: "NESTED", type: .select, proxies: ["SELECT", "DIRECT"]),
            PolicyGroup(name: "FALL", type: .fallback, proxies: ["P1"]),
            PolicyGroup(name: "LB", type: .loadBalance, proxies: ["P1", "P2"]),
            PolicyGroup(name: "BLOCK", type: .reject, proxies: ["REJECT"]),
            PolicyGroup(name: "PINNED", type: .select, proxies: ["P1", "P2"], selected: "P2"),
            PolicyGroup(name: "CYCLE-A", type: .select, proxies: ["CYCLE-B"]),
            PolicyGroup(name: "CYCLE-B", type: .select, proxies: ["CYCLE-A"]),
            PolicyGroup(name: "BROKEN", type: .select, proxies: ["NOPE"]),
        ]
        let profile = Profile(name: "groups", outbounds: [.direct, .reject, p1, p2], groups: groups)

        let resolver = PolicyResolver(profile: profile)
        XCTAssertEqual(resolver.resolve("SELECT").name, "P1")
        XCTAssertEqual(resolver.resolve("NESTED").name, "P1")
        XCTAssertEqual(resolver.resolve("FALL").name, "P1")
        XCTAssertEqual(resolver.resolve("BLOCK").type, .reject)
        XCTAssertEqual(resolver.resolve("PINNED").name, "P2")
        XCTAssertEqual(resolver.resolve("direct").name, "DIRECT")
        XCTAssertEqual(resolver.resolve("NOPE").name, "DIRECT")

        var lbNames = Set<String>()
        lbNames.insert(resolver.resolve("LB").name)
        lbNames.insert(resolver.resolve("LB").name)
        XCTAssertEqual(lbNames, ["P1", "P2"])

        let selected = PolicyResolver(profile: profile, selections: ["select": "P2"])
        XCTAssertEqual(selected.resolve("SELECT").name, "P2")
        XCTAssertEqual(selected.resolve("NESTED").name, "P2")
        selected.setSelection(group: "SELECT", outbound: "P1")
        XCTAssertEqual(selected.resolve("SELECT").name, "P1")
        XCTAssertEqual(selected.selections["select"], "P1")

        XCTAssertEqual(resolver.resolve("CYCLE-A").name, "DIRECT")

        let issues = resolver.validate()
        XCTAssertTrue(issues.contains { $0.contains("cycle") }, "issues: \(issues)")
        XCTAssertTrue(issues.contains { $0.contains("NOPE") }, "issues: \(issues)")
        XCTAssertTrue(resolver.policyNames.contains("SELECT"))
    }

    // MARK: 8. Filter parsing

    func testFilterParserSyntax() throws {
        let text = """
        ! a comment
        [Adblock Plus 2.0]
        ||ads.example.com^
        |http://tracker.test/pixel
        @@||ok.example.com^
        ||third.test^$third-party
        0.0.0.0 hosts.test
        127.0.0.1 hosts2.test
        example.com##.ad
        example.com#@#.ok
        """
        let parsed = FilterParser.parse(text)
        XCTAssertEqual(parsed.block.count, 5)
        XCTAssertEqual(parsed.allow.count, 1)
        XCTAssertEqual(parsed.cosmetic.count, 2)

        XCTAssertEqual(parsed.block.first?.domain, "ads.example.com")
        XCTAssertEqual(parsed.allow.first?.domain, "ok.example.com")
        XCTAssertTrue(parsed.allow.first?.isException == true)
        XCTAssertTrue(parsed.block.contains { $0.domain == "third.test" && $0.thirdPartyOnly })
        XCTAssertTrue(parsed.block.contains { $0.domain == "hosts.test" })
        XCTAssertTrue(parsed.block.contains { $0.domain == "tracker.test" })
        XCTAssertEqual(parsed.cosmetic.first?.selector, ".ad")
        XCTAssertFalse(parsed.cosmetic.first?.isException ?? true)
        XCTAssertTrue(parsed.cosmetic.last?.isException == true)
    }

    // MARK: 9. AdBlock verdicts, exceptions, cosmetics

    func testAdBlockVerdictsAndCosmetics() {
        let text = """
        ||ads.example.com^
        |http://tracker.test/pixel
        @@||ok.example.com^
        ||third.test^$third-party
        0.0.0.0 hosts.test
        example.com##.ad
        example.com#@#.ok
        example.org##.banner
        """
        let parsed = FilterParser.parse(text)
        let engine = AdBlockEngine(blockRules: parsed.block, allowRules: parsed.allow,
                                  cosmeticRules: parsed.cosmetic, allowList: ["allowed.test"])

        let blocked = engine.verdict(for: "ads.example.com", thirdParty: false)
        XCTAssertTrue(blocked.blocked)
        XCTAssertEqual(blocked.reason, "||ads.example.com^")

        XCTAssertTrue(engine.verdict(for: "sub.ads.example.com", thirdParty: false).blocked)
        XCTAssertFalse(engine.verdict(for: "notads.example.com", thirdParty: false).blocked)

        XCTAssertFalse(engine.verdict(for: "ok.example.com", thirdParty: false).blocked)
        XCTAssertFalse(engine.verdict(for: "x.ok.example.com", thirdParty: false).blocked)
        XCTAssertFalse(engine.verdict(for: "allowed.test", thirdParty: false).blocked)
        XCTAssertFalse(engine.verdict(for: "deep.allowed.test", thirdParty: false).blocked)

        XCTAssertFalse(engine.verdict(for: "third.test", thirdParty: false).blocked)
        XCTAssertTrue(engine.verdict(for: "third.test", thirdParty: true).blocked)

        // |http://tracker.test/pixel is URL-anchored: it must only fire for that path.
        XCTAssertFalse(engine.verdict(for: "tracker.test", thirdParty: false).blocked)
        XCTAssertTrue(engine.verdict(for: "tracker.test", path: "/pixel", thirdParty: false).blocked)

        XCTAssertTrue(engine.verdict(for: "hosts.test", thirdParty: false).blocked)
        XCTAssertTrue(engine.isBlocked("hosts.test"))

        XCTAssertEqual(engine.cosmeticSelectors(for: "example.com"), [".ad"])
        XCTAssertEqual(engine.cosmeticSelectors(for: "sub.example.com"), [".ad"])
        XCTAssertEqual(engine.cosmeticSelectors(for: "example.org"), [".banner"])
        XCTAssertEqual(engine.cosmeticSelectors(for: "other.test"), [])

        XCTAssertEqual(engine.ruleCount, parsed.block.count + parsed.allow.count
                        + parsed.cosmetic.count + 1)
    }

    // MARK: 10. Performance

    func testAdBlockPerformance() {
        let count = 100_000
        var lines: [String] = []
        lines.reserveCapacity(count)
        for i in 0..<count {
            lines.append("||host\(i).zone\(i % 977).test^")
        }
        let text = lines.joined(separator: "\n")

        // Best-of-3: a single sample is noisy when the rest of the suite runs in parallel.
        var loadTime = Double.greatestFiniteMagnitude
        var engine = AdBlockEngine()
        for _ in 0..<3 {
            let loadStart = Date()
            let parsed = FilterParser.parse(text)
            engine = AdBlockEngine(blockRules: parsed.block, allowRules: parsed.allow)
            loadTime = min(loadTime, Date().timeIntervalSince(loadStart))
        }
        XCTAssertEqual(engine.ruleCount, count)
        XCTAssertLessThan(loadTime, 1.0, "loading \(count) filters took \(loadTime)s")
        XCTAssertTrue(engine.verdict(for: "host4242.zone\(4242 % 977).test", thirdParty: true).blocked)

        let queries = 1_000
        var perQuery = Double.greatestFiniteMagnitude
        var hits = 0
        for _ in 0..<3 {
            let queryStart = Date()
            var roundHits = 0
            for i in 0..<queries {
                let index = (i * 7919) % count
                if engine.verdict(for: "host\(index).zone\(index % 977).test", thirdParty: false).blocked {
                    roundHits += 1
                }
            }
            perQuery = min(perQuery, Date().timeIntervalSince(queryStart) / Double(queries))
            hits = max(hits, roundHits)
        }
        XCTAssertEqual(hits, queries)
        XCTAssertLessThan(perQuery, 50e-6, "average query \(perQuery * 1e6)µs, load \(loadTime)s")
    }

    // MARK: 11. Export round-trip

    func testExportRoundTrip() throws {
        let lines = [
            "DOMAIN,example.com,PROXY",
            "DOMAIN-SUFFIX,ads.test,DIRECT,no-resolve",
            "IP-CIDR,1.2.3.0/24,PROXY",
            "IP-CIDR6,2001:db8::/32,PROXY",
            "PROCESS-NAME,WeChat,DIRECT",
            "GEOIP,CN,DIRECT",
            "RULE-SET,ads,REJECT",
            "AND,((DOMAIN,a.com),(DOMAIN-SUFFIX,b.com)),PROXY",
            "!DOMAIN,neg.test,REJECT",
            "MATCH,PROXY",
        ]
        let original = try lines.map { try RuleParser.parse(line: $0) }

        for exported in [RuleParser.exportSurge(original), RuleParser.exportClash(original)] {
            let (reparsed, errors) = RuleParser.parseRules(exported)
            XCTAssertTrue(errors.isEmpty, "errors: \(errors) for:\n\(exported)")
            XCTAssertEqual(reparsed.count, original.count)
            for (lhs, rhs) in zip(original, reparsed) {
                XCTAssertEqual(lhs.kind, rhs.kind, exported)
                XCTAssertEqual(lhs.value, rhs.value, exported)
                XCTAssertEqual(lhs.policy, rhs.policy, exported)
                XCTAssertEqual(lhs.negate, rhs.negate, exported)
                XCTAssertEqual(lhs.modifiers, rhs.modifiers, exported)
            }
        }

        XCTAssertTrue(RuleParser.exportSurge([try r("MATCH,PROXY")]).hasPrefix("FINAL,"))
        XCTAssertTrue(RuleParser.exportClash([try r("FINAL,PROXY")]).hasPrefix("MATCH,"))
    }

    // MARK: 11b. Scale: 10k rules, one decide under the 5 ms budget

    func testRuleEngineScale() throws {
        var rules: [Rule] = []
        rules.reserveCapacity(10_001)
        for i in 0..<10_000 {
            rules.append(try r("DOMAIN-SUFFIX,host\(i).zone\(i % 500).test,DIRECT"))
        }
        rules.append(try r("MATCH,PROXY"))

        let engine = RuleEngine(profile: profile(rules: rules))
        XCTAssertEqual(engine.ruleCount, 10_001)

        let hit = meta("a.host9999.zone\(9999 % 500).test")
        let miss = meta("nomatch.example.com")
        _ = engine.decide(hit)
        _ = engine.decide(miss)

        // Best-of-5 per measurement; a single sample is scheduler-noise sensitive.
        func bestDecide(_ meta: ConnectionMeta) -> (RouteDecision, Double) {
            var best = (RouteDecision(policy: "", outbound: .direct), Double.greatestFiniteMagnitude)
            for _ in 0..<5 {
                let start = Date()
                let decision = engine.decide(meta)
                best = (decision, min(best.1, Date().timeIntervalSince(start)))
            }
            return best
        }
        let (hitDecision, hitElapsed) = bestDecide(hit)
        XCTAssertEqual(hitDecision.policy, "DIRECT")
        XCTAssertLessThan(hitElapsed, 0.005, "10k-rule hit took \(hitElapsed * 1000)ms")

        let (missDecision, missElapsed) = bestDecide(miss)
        XCTAssertEqual(missDecision.policy, "PROXY")
        XCTAssertLessThan(missElapsed, 0.005, "10k-rule miss took \(missElapsed * 1000)ms")
    }

    // MARK: 12. Rule set loading

    func testRuleSetLoader() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tf-policy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("ads.list")
        try """
        # rule set
        DOMAIN-SUFFIX,ads.test
        DOMAIN,exact.test,REJECT
        """.write(to: file, atomically: true, encoding: .utf8)

        let sets = await RuleSetLoader.load(sources: [file.path, "/nonexistent/missing.list"],
                                            cacheDirectory: directory)
        XCTAssertEqual(sets["ads"]?.count, 2, "keys: \(sets.keys.sorted())")
        XCTAssertEqual(sets["ads"]?.first?.value, "ads.test")
        XCTAssertEqual(sets["missing"]?.count, 0)

        let engine = RuleEngine(profile: profile(rules: [try r("RULE-SET,ads,PROXY"), try r("MATCH,DIRECT")]),
                                ruleSets: sets)
        XCTAssertEqual(engine.decide(meta("x.ads.test")).policy, "PROXY")
        XCTAssertEqual(engine.decide(meta("other.test")).policy, "DIRECT")
    }
}
