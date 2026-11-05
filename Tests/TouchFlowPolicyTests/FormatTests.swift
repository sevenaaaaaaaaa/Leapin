import XCTest
import Foundation
@testable import TouchFlowPolicy
import TouchFlowCore

/// Format-layer tests: Clash / Surge / subscription / rule-set / ABP round-trips.
/// These live in TouchFlowPolicyTests because Package.swift has no Runtime test
/// target and the target structure must not change.
final class FormatTests: XCTestCase {

    // MARK: - Helpers

    private func importClash(_ text: String) throws -> ProfileImportOutcome {
        try ProfileImporter.importText(text, name: "测试", pathExtension: "yaml")
    }

    private func importSurge(_ text: String) throws -> ProfileImportOutcome {
        try ProfileImporter.importText(text, name: "测试", pathExtension: "conf")
    }

    private func clashFixture() -> String {
        """
        mixed-port: 7890
        port: 7891
        socks-port: 7892
        allow-lan: true
        log-level: warning
        dns:
          enable: true
          listen: 0.0.0.0:1053
          enhanced-mode: fake-ip
          fake-ip-range: 198.19.0.0/16
          nameserver:
            - https://dns.example/dns-query
          fallback:
            - 223.5.5.5
          hosts:
            router.lan:
              - 192.168.1.1
          nameserver-policy:
            "geosite:cn":
              - 223.5.5.5
          fake-ip-filter:
            - "*.lan"
            - "+.local"
        proxies:
          - name: "香港 01"
            type: ss
            server: hk.example.com
            port: 8388
            cipher: aes-256-gcm
            password: "p@ss:word"
            udp: true
          - name: vless-01
            type: vless
            server: v.example.com
            port: 443
            uuid: 11111111-2222-3333-4444-555555555555
            network: ws
            tls: true
            sni: v.example.com
            ws-opts:
              path: /ray
              headers:
                Host: cdn.example.com
          - name: hy2-01
            type: hysteria2
            server: h.example.com
            port: 443
            password: secret
            sni: h.example.com
            skip-cert-verify: true
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - DIRECT
              - "香港 01"
              - vless-01
              - hy2-01
          - name: AUTO
            type: url-test
            use:
              - sub
            url: https://www.gstatic.com/generate_204
            interval: 300
          - name: RELAY
            type: relay
            proxies:
              - "香港 01"
              - vless-01
        rule-providers:
          cn:
            type: http
            behavior: domain
            url: https://example.com/cn.yaml
            path: ./ruleset/cn.yaml
            interval: 86400
        rules:
          - DOMAIN-SUFFIX,*.google.com,PROXY
          - RULE-SET,cn,PROXY
          - MATCH,DIRECT
        """
    }

    // MARK: - 1. Clash import keeps everything the model can hold

    func testClashImportKeepsFields() throws {
        let outcome = try importClash(clashFixture())
        let p = outcome.profile

        XCTAssertEqual(p.general.mixedPort, 7890)
        XCTAssertEqual(p.general.httpPort, 7891)
        XCTAssertEqual(p.general.socksPort, 7892)
        XCTAssertTrue(p.general.allowLAN)
        XCTAssertEqual(p.general.logLevel, .warning)

        XCTAssertEqual(p.dns.listenPort, 1053)
        XCTAssertEqual(p.dns.mode, .fakeIP)
        XCTAssertEqual(p.dns.fakeIPRange, "198.19.0.0/16")
        XCTAssertEqual(p.dns.hosts["router.lan"], "192.168.1.1")
        XCTAssertEqual(p.dns.nameserverPolicy["geosite:cn"], ["223.5.5.5"])
        XCTAssertEqual(p.dns.fakeIPFilter, ["*.lan", "+.local"])

        XCTAssertEqual(p.outbounds.count, 5)
        XCTAssertEqual(p.outbounds.map(\.name), ["DIRECT", "REJECT", "香港 01", "vless-01", "hy2-01"])

        let ss = try XCTUnwrap(p.outbounds.first { $0.name == "香港 01" })
        XCTAssertEqual(ss.type, .shadowsocks)
        XCTAssertEqual(ss.cipher, "aes-256-gcm")
        XCTAssertEqual(ss.password, "p@ss:word")
        XCTAssertEqual(ss.udp, true)

        let vless = try XCTUnwrap(p.outbounds.first { $0.name == "vless-01" })
        XCTAssertEqual(vless.type, .vless)
        XCTAssertEqual(vless.rawType, "vless")
        XCTAssertFalse(vless.type.isDialable)
        XCTAssertEqual(vless.uuid, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(vless.network, "ws")
        XCTAssertEqual(vless.wsPath, "/ray")
        XCTAssertEqual(vless.wsHost, "cdn.example.com")
        XCTAssertTrue(vless.tls)

        let hy2 = try XCTUnwrap(p.outbounds.first { $0.name == "hy2-01" })
        XCTAssertEqual(hy2.type, .hysteria2)
        XCTAssertEqual(hy2.password, "secret")
        XCTAssertEqual(hy2.skipCertVerify, true)

        XCTAssertEqual(p.groups.count, 3)
        let auto = try XCTUnwrap(p.groups.first { $0.name == "AUTO" })
        XCTAssertEqual(auto.type, .urlTest)
        XCTAssertEqual(auto.use, ["sub"])
        XCTAssertEqual(auto.url, "https://www.gstatic.com/generate_204")
        XCTAssertEqual(auto.interval, 300)

        let relay = try XCTUnwrap(p.groups.first { $0.name == "RELAY" })
        XCTAssertEqual(relay.rawType, "relay")
        XCTAssertEqual(relay.proxies, ["香港 01", "vless-01"])
        XCTAssertTrue(outcome.report.issues.contains { $0.kind == .unknownGroupType && $0.item == "relay" })

        let provider = try XCTUnwrap(p.ruleProviders.first { $0.name == "cn" })
        XCTAssertEqual(provider.type, "http")
        XCTAssertEqual(provider.behavior, "domain")
        XCTAssertEqual(provider.url, "https://example.com/cn.yaml")
        XCTAssertEqual(provider.path, "./ruleset/cn.yaml")
        XCTAssertEqual(provider.interval, 86400)

        XCTAssertEqual(p.rules.count, 3)
        XCTAssertEqual(p.rules[0].kind, .domainSuffix)
        XCTAssertEqual(p.rules[0].value, "google.com")
        XCTAssertEqual(p.rules[1].kind, .ruleSet)
        XCTAssertEqual(p.rules[1].value, "cn")
        XCTAssertEqual(p.rules[2].kind, .match)

        // The fixture deliberately uses a provider-based group, a Clash relay and two
        // protocols this build cannot dial: all three must be reported instead of
        // silently degraded.
        XCTAssertFalse(outcome.report.isClean)
        XCTAssertTrue(outcome.report.issues.contains { $0.item == "AUTO" })
        XCTAssertTrue(outcome.report.issues.contains { $0.item == "relay" && $0.kind == .unknownGroupType })
        XCTAssertEqual(Set(outcome.report.notDialable), ["vless-01", "hy2-01"])
        XCTAssertEqual(outcome.report.issues.filter { $0.kind == .unknownProtocol }.count, 2)
        XCTAssertTrue(outcome.report.summary.contains("暂不可拨号"), outcome.report.summary)
    }

    // MARK: - 2. Unknown protocols are kept verbatim, not dropped

    func testClashUnknownProtocolKept() throws {
        let text = """
        proxies:
          - name: weird
            type: naive+http3
            server: w.example.com
            port: 443
            some-new-key: 42
        """
        let outcome = try importClash(text)
        XCTAssertEqual(outcome.profile.outbounds.count, 3)
        let ob = try XCTUnwrap(outcome.profile.outbounds.last)
        XCTAssertEqual(ob.name, "weird")
        XCTAssertEqual(ob.type, .unsupported)
        XCTAssertEqual(ob.rawType, "naive+http3")
        XCTAssertEqual(ob.host, "w.example.com")
        XCTAssertEqual(ob.extra["some-new-key"], "42")
        XCTAssertEqual(outcome.report.unknownProtocols, ["naive+http3"])
        XCTAssertEqual(outcome.report.skippedOutbounds, 0)
    }

    // MARK: - 3. BOM and empty rules must not silently rewrite the profile

    func testClashBOMStripped() throws {
        let outcome = try importClash("\u{FEFF}" + "proxies:\n  - name: a\n    type: ss\n    server: a.example.com\n    port: 8388\n    cipher: aes-128-gcm\n    password: pw\n")
        XCTAssertEqual(outcome.profile.outbounds.count, 3)
        XCTAssertEqual(outcome.profile.outbounds.last?.name, "a")
        XCTAssertTrue(outcome.profile.rules.isEmpty)
    }

    func testClashEmptyRulesNotBackfilled() throws {
        let outcome = try importClash("mixed-port: 7890\nrules: []\n")
        XCTAssertTrue(outcome.profile.rules.isEmpty, "imported profile must not get baseRules injected")
    }

    // MARK: - 4. Clash round-trip

    func testClashRoundTripSemantics() throws {
        let first = try importClash(clashFixture())
        let exported = ProfileExporter.clash(first.profile)
        let second = try importClash(exported)

        XCTAssertEqual(second.profile.outbounds.map(\.name), first.profile.outbounds.map(\.name))
        for name in ["香港 01", "vless-01", "hy2-01"] {
            let a = try XCTUnwrap(first.profile.outbounds.first { $0.name == name })
            let b = try XCTUnwrap(second.profile.outbounds.first { $0.name == name })
            XCTAssertEqual(a.type, b.type, "type drift for \(name)")
            XCTAssertEqual(a.host, b.host)
            XCTAssertEqual(a.port, b.port)
            XCTAssertEqual(a.uuid, b.uuid)
            XCTAssertEqual(a.wsPath, b.wsPath)
            XCTAssertEqual(a.wsHost, b.wsHost)
            XCTAssertEqual(a.cipher, b.cipher)
            XCTAssertEqual(a.password, b.password)
            XCTAssertEqual(a.udp, b.udp)
        }
        XCTAssertEqual(second.profile.groups.map(\.name), first.profile.groups.map(\.name))
        XCTAssertEqual(second.profile.groups.first { $0.name == "RELAY" }?.rawType, "relay")
        XCTAssertEqual(second.profile.groups.first { $0.name == "AUTO" }?.use, ["sub"])
        XCTAssertEqual(second.profile.dns.nameserverPolicy, first.profile.dns.nameserverPolicy)
        XCTAssertEqual(second.profile.dns.fakeIPFilter, first.profile.dns.fakeIPFilter)
        XCTAssertEqual(second.profile.dns.hosts, first.profile.dns.hosts)
        XCTAssertEqual(second.profile.ruleProviders.map(\.name), first.profile.ruleProviders.map(\.name))
        XCTAssertEqual(second.profile.ruleProviders.first?.url, first.profile.ruleProviders.first?.url)
        XCTAssertEqual(RuleParser.exportClash(second.profile.rules),
                       RuleParser.exportClash(first.profile.rules))
    }

    // MARK: - 5. YAML scalar quoting survives a parse

    func testYAMLScalarQuotingRoundTrip() throws {
        let cases = ["a: b", "x#y", "true", "007", "", "a\"b", "c\\d", "- x",
                     "香港 01", "[x]", "a,b", "p@ss:word", " leading", "trailing "]
        for value in cases {
            let yaml = "k: \(ProfileExporter.yamlScalar(value))\n"
            let parsed = try MiniYAML.parse(yaml)["k"]?.string
            XCTAssertEqual(parsed, value, "scalar \(value.debugDescription) did not survive")
        }
    }

    // MARK: - 6. Surge import / export round-trip

    private func surgeFixture() -> String {
        """
        [General]
        loglevel = info
        http-listen = 0.0.0.0:6152
        socks5-listen = 0.0.0.0:6153
        allow-lan = true
        dns-server = 223.5.5.5, 119.29.29.29

        [Proxy]
        HK = ss, hk.example.com, 8388, encrypt-method=aes-256-gcm, password=pw, udp-relay=true
        TRO = trojan, t.example.com, 443, password=tpw, sni=t.example.com
        TP = http, h.example.com, 8080, user, pass

        [Proxy Group]
        PROXY = select, HK, TRO, TP
        AUTO = url-test, HK, TRO, url = http://www.gstatic.com/generate_204, interval = 300

        [Rule]
        DOMAIN-SUFFIX,google.com,PROXY
        FINAL,DIRECT

        [Host]
        router.lan = 192.168.1.1
        """
    }

    func testSurgeImport() throws {
        let outcome = try importSurge(surgeFixture())
        let p = outcome.profile

        XCTAssertEqual(p.general.httpPort, 6152)
        XCTAssertEqual(p.general.socksPort, 6153)
        XCTAssertTrue(p.general.allowLAN)
        XCTAssertEqual(p.dns.upstreams, ["223.5.5.5", "119.29.29.29"])
        XCTAssertEqual(p.dns.hosts["router.lan"], "192.168.1.1")

        XCTAssertEqual(p.outbounds.count, 5)
        let hk = try XCTUnwrap(p.outbounds.first { $0.name == "HK" })
        XCTAssertEqual(hk.type, .shadowsocks)
        XCTAssertEqual(hk.cipher, "aes-256-gcm")
        XCTAssertEqual(hk.password, "pw")
        XCTAssertEqual(hk.udp, true)
        XCTAssertEqual(hk.host, "hk.example.com")
        XCTAssertEqual(hk.port, 8388)

        let tro = try XCTUnwrap(p.outbounds.first { $0.name == "TRO" })
        XCTAssertEqual(tro.type, .trojan)
        XCTAssertTrue(tro.tls)
        XCTAssertEqual(tro.sni, "t.example.com")

        let tp = try XCTUnwrap(p.outbounds.first { $0.name == "TP" })
        XCTAssertEqual(tp.username, "user")
        XCTAssertEqual(tp.password, "pass")

        let auto = try XCTUnwrap(p.groups.first { $0.name == "AUTO" })
        XCTAssertEqual(auto.type, .urlTest)
        XCTAssertEqual(auto.proxies, ["HK", "TRO"], "surge group members")
        XCTAssertEqual(auto.interval, 300)

        XCTAssertEqual(p.rules.count, 2)
        XCTAssertEqual(p.rules.last?.kind, .match)
        XCTAssertTrue(outcome.report.isClean, "unexpected issues: \(outcome.report.issues.map(\.display))")
    }

    func testSurgeRoundTrip() throws {
        let first = try importSurge(surgeFixture())
        let exported = ProfileExporter.surge(first.profile)
        let second = try importSurge(exported)

        XCTAssertEqual(second.profile.outbounds.map(\.name), first.profile.outbounds.map(\.name))
        XCTAssertEqual(second.profile.groups.map(\.name), first.profile.groups.map(\.name))
        XCTAssertEqual(second.profile.dns.hosts, first.profile.dns.hosts)
        XCTAssertEqual(second.profile.general.httpPort, first.profile.general.httpPort)
        XCTAssertEqual(second.profile.general.socksPort, first.profile.general.socksPort)
        XCTAssertEqual(RuleParser.exportSurge(second.profile.rules),
                       RuleParser.exportSurge(first.profile.rules))
    }

    func testSurgeUnparsableProxyIsDiagnosed() throws {
        let text = """
        [Proxy]
        OK = ss, a.example.com, 8388, encrypt-method=aes-128-gcm, password=pw
        BAD = anytls, b.example.com, 443
        """
        let outcome = try importSurge(text)
        XCTAssertEqual(outcome.profile.outbounds.count, 3)
        XCTAssertEqual(outcome.report.skippedOutbounds, 1)
        XCTAssertTrue(outcome.report.issues.contains { $0.kind == .skippedItem && $0.line == 3 })
    }

    // MARK: - 7. Rule parsing: wildcard suffix, rule-set members

    func testRuleWildcardSuffixIsMatchable() throws {
        let rule = try RuleParser.parse(line: "DOMAIN-SUFFIX,*.google.com,PROXY")
        XCTAssertEqual(rule.kind, .domainSuffix)
        XCTAssertEqual(rule.value, "google.com")
        XCTAssertTrue(HostNormalizer.matchesSuffix("www.google.com", rule.value))
        XCTAssertTrue(HostNormalizer.matchesSuffix("google.com", rule.value))

        let wildcard = try RuleParser.parse(line: "DOMAIN-WILDCARD,*.ads.example,REJECT")
        XCTAssertEqual(wildcard.kind, .domainSuffix)
        XCTAssertEqual(wildcard.value, "ads.example")

        let dotted = try RuleParser.parse(line: "DOMAIN-SUFFIX,.blogger.com,DIRECT")
        XCTAssertEqual(dotted.value, "blogger.com")
    }

    func testRuleSetMembers() {
        let text = """
        payload:
          - '+.google.com'
          - ".blogger.com"
          - 10.0.0.0/8
          - DOMAIN,ads.example,PROXY
        """
        let parsed = RuleParser.parseRules(text)
        XCTAssertTrue(parsed.errors.isEmpty, "\(parsed.errors)")
        XCTAssertEqual(parsed.rules.count, 4)
        XCTAssertEqual(parsed.rules[0].kind, .domainSuffix)
        XCTAssertEqual(parsed.rules[0].value, "google.com")
        XCTAssertEqual(parsed.rules[0].policy, "")
        XCTAssertEqual(parsed.rules[1].kind, .domainSuffix)
        XCTAssertEqual(parsed.rules[1].value, "blogger.com")
        XCTAssertEqual(parsed.rules[2].kind, .ipCIDR)
        XCTAssertEqual(parsed.rules[2].value, "10.0.0.0/8")
        XCTAssertEqual(parsed.rules[3].kind, .domain)
        XCTAssertEqual(parsed.rules[3].policy, "PROXY")
    }

    // MARK: - 8. ABP: scope, path rules, BOM

    func testFilterDomainScopeLimitsRule() {
        let parsed = FilterParser.parse("||track.example.com^$domain=news.example.com|~sub.news.example.com")
        let rule = parsed.block.first
        XCTAssertEqual(rule?.domain, "track.example.com")
        XCTAssertEqual(rule?.scope, ["news.example.com"])
        XCTAssertEqual(rule?.excludedScope, ["sub.news.example.com"])

        let engine = AdBlockEngine(blockRules: parsed.block, allowRules: parsed.allow,
                                   cosmeticRules: parsed.cosmetic)
        XCTAssertFalse(engine.verdict(for: "track.example.com", thirdParty: false).blocked,
                       "out-of-scope request must not be blocked")
    }

    func testFilterPathRuleDoesNotBlockWholeDomain() throws {
        let parsed = FilterParser.parse("|https://cdn.example.com/ads/banner.js")
        let rule = try XCTUnwrap(parsed.block.first)
        XCTAssertEqual(rule.domain, "cdn.example.com")
        XCTAssertEqual(rule.pathPrefix, "/ads/banner.js")
        XCTAssertTrue(rule.requiresPathMatch)

        let engine = AdBlockEngine(blockRules: parsed.block, allowRules: parsed.allow,
                                   cosmeticRules: parsed.cosmetic)
        XCTAssertFalse(engine.verdict(for: "cdn.example.com", thirdParty: false).blocked,
                       "a URL rule must not become a whole-domain block")
        XCTAssertTrue(engine.verdict(for: "cdn.example.com", path: "/ads/banner.js",
                                     thirdParty: false).blocked)
        XCTAssertFalse(engine.verdict(for: "cdn.example.com", path: "/app.js",
                                      thirdParty: false).blocked)
    }

    func testFilterBOMDoesNotDegradeFirstRule() {
        let parsed = FilterParser.parse("\u{FEFF}||a.example.com^\n||b.example.com^")
        XCTAssertEqual(parsed.block.count, 2)
        XCTAssertEqual(parsed.block[0].domain, "a.example.com")
        XCTAssertEqual(parsed.block[1].domain, "b.example.com")
    }

    // MARK: - 9. Subscriptions and shadowsocks URIs

    func testWholeDocumentBase64Subscription() throws {
        let payload = """
        ss://aes-256-gcm:pass@1.2.3.4:8388#HK
        trojan://tpw@t.example.com:443?sni=t.example.com#TRO
        """
        let encoded = Data(payload.utf8).base64EncodedString()
        let outcome = try ProfileImporter.importText(encoded, name: "订阅")
        XCTAssertEqual(outcome.profile.outbounds.count, 4)
        XCTAssertEqual(outcome.profile.outbounds.map(\.name).suffix(2), ["HK", "TRO"])

        let ss = try XCTUnwrap(outcome.profile.outbounds.first { $0.name == "HK" })
        XCTAssertEqual(ss.type, .shadowsocks)
        XCTAssertEqual(ss.cipher, "aes-256-gcm")
        XCTAssertEqual(ss.password, "pass")
        XCTAssertEqual(ss.host, "1.2.3.4")
        XCTAssertEqual(ss.port, 8388)

        let trojan = try XCTUnwrap(outcome.profile.outbounds.first { $0.name == "TRO" })
        XCTAssertEqual(trojan.type, .trojan)
        XCTAssertEqual(trojan.password, "tpw")
        XCTAssertTrue(trojan.tls)
        XCTAssertEqual(outcome.profile.groups.first?.name, "PROXY")
    }

    func testShadowsocksSIP002AndLegacy() throws {
        let sip002 = try XCTUnwrap(SubscriptionImporter.parse("ss://aes-128-gcm:pw@5.6.7.8:8389#SIP").outbounds.first)
        XCTAssertEqual(sip002.cipher, "aes-128-gcm")
        XCTAssertEqual(sip002.password, "pw")
        XCTAssertEqual(sip002.host, "5.6.7.8")
        XCTAssertEqual(sip002.port, 8389)

        let userInfo = Data("aes-128-gcm:pw@5.6.7.9:8390".utf8).base64EncodedString()
        let legacy = try XCTUnwrap(SubscriptionImporter.parse("ss://\(userInfo)#Legacy").outbounds.first)
        XCTAssertEqual(legacy.cipher, "aes-128-gcm")
        XCTAssertEqual(legacy.password, "pw")
        XCTAssertEqual(legacy.host, "5.6.7.9")
        XCTAssertEqual(legacy.port, 8390)
    }

    func testVmessAndHysteria2URIs() throws {
        let vmessJSON = #"{"v":"2","ps":"VM","add":"vm.example.com","port":"443","id":"abcd-uuid","aid":"0","net":"ws","path":"/ws","host":"cdn.example.com","tls":"tls"}"#
        let encoded = Data(vmessJSON.utf8).base64EncodedString()
        let vmess = try XCTUnwrap(SubscriptionImporter.parse("vmess://\(encoded)").outbounds.first)
        XCTAssertEqual(vmess.type, .vmess)
        XCTAssertEqual(vmess.name, "VM")
        XCTAssertEqual(vmess.uuid, "abcd-uuid")
        XCTAssertEqual(vmess.network, "ws")
        XCTAssertEqual(vmess.wsPath, "/ws")
        XCTAssertEqual(vmess.wsHost, "cdn.example.com")
        XCTAssertTrue(vmess.tls)

        let hy2 = try XCTUnwrap(SubscriptionImporter.parse("hysteria2://pw@h.example.com:8443?sni=h.example.com&insecure=1&obfs=salamander&obfs-password=op#HY").outbounds.first)
        XCTAssertEqual(hy2.type, .hysteria2)
        XCTAssertEqual(hy2.password, "pw")
        XCTAssertEqual(hy2.port, 8443)
        XCTAssertEqual(hy2.obfs, "salamander")
        XCTAssertEqual(hy2.obfsPassword, "op")
        XCTAssertEqual(hy2.skipCertVerify, true)
    }

    // MARK: - 10. Detection and JSON compatibility

    func testFormatDetection() {
        XCTAssertEqual(ProfileFormatDetector.detect(text: clashFixture()), .clash)
        XCTAssertEqual(ProfileFormatDetector.detect(text: surgeFixture()), .surge)
        XCTAssertEqual(ProfileFormatDetector.detect(text: "{\"name\":\"x\"}"), .json)
        XCTAssertEqual(ProfileFormatDetector.detect(text: "ss://YWVzLTI1Ni1nY206cGFzcw==@1.2.3.4:8388#HK"), .subscription)
        XCTAssertEqual(ProfileFormatDetector.detect(text: Data("ss://a:b@1.2.3.4:1#x".utf8).base64EncodedString()), .subscription)
        XCTAssertEqual(ProfileFormatDetector.detect(text: "完全不是配置"), .unknown)
    }

    func testLegacyJSONProfileStillDecodes() throws {
        let legacy = Data("{\"name\":\"旧配置\"}".utf8)
        let outcome = try ProfileImporter.json(legacy, name: "旧配置")
        XCTAssertEqual(outcome.profile.name, "旧配置")
        XCTAssertTrue(outcome.profile.ruleProviders.isEmpty)
        XCTAssertEqual(outcome.profile.outbounds.map(\.name), ["DIRECT", "REJECT"])

        var profile = ProfileDefaults.make()
        profile.dns.nameserverPolicy = ["+.corp.example": ["10.0.0.53"]]
        profile.dns.fakeIPFilter = ["*.lan"]
        profile.ruleProviders = [RuleProvider(name: "cn", type: "http", behavior: "domain",
                                              url: "https://example.com/cn.yaml")]
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(decoded.dns.nameserverPolicy, profile.dns.nameserverPolicy)
        XCTAssertEqual(decoded.dns.fakeIPFilter, profile.dns.fakeIPFilter)
        XCTAssertEqual(decoded.ruleProviders, profile.ruleProviders)
    }

    // MARK: - 11. Full import -> export -> import equivalence

    func testImportExportImportEquivalence() throws {
        let text = """
        mixed-port: 7890
        proxies:
          - name: "节点: 日本"
            type: vmess
            server: jp.example.com
            port: 443
            uuid: 22222222-3333-4444-5555-666666666666
            alterId: 0
            network: grpc
            grpc-opts:
              grpc-service-name: gun
            tls: true
          - name: future
            type: quantum
            server: q.example.com
            port: 443
        proxy-groups:
          - name: RELAY
            type: relay
            proxies:
              - "节点: 日本"
              - future
        rules:
          - DOMAIN-SUFFIX,*.blogger.com,RELAY
          - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
        """
        let first = try importClash(text)
        let exported = ProfileExporter.clash(first.profile)
        let second = try importClash(exported)

        let a = first.profile.outbounds.filter { $0.name != "DIRECT" && $0.name != "REJECT" }
        let b = second.profile.outbounds.filter { $0.name != "DIRECT" && $0.name != "REJECT" }
        XCTAssertEqual(b.map(\.name), a.map(\.name))
        XCTAssertEqual(b.map(\.type), a.map(\.type))
        XCTAssertEqual(b.map(\.rawType), a.map(\.rawType))
        let vmessA = try XCTUnwrap(a.first { $0.name == "节点: 日本" })
        let vmessB = try XCTUnwrap(b.first { $0.name == "节点: 日本" })
        XCTAssertEqual(vmessB.grpcServiceName, vmessA.grpcServiceName)
        XCTAssertEqual(vmessB.alterId, vmessA.alterId)
        XCTAssertEqual(second.profile.groups.first?.rawType, "relay")
        XCTAssertEqual(second.profile.groups.first?.proxies, ["节点: 日本", "future"])
        XCTAssertEqual(RuleParser.exportClash(second.profile.rules),
                       RuleParser.exportClash(first.profile.rules))
        XCTAssertTrue(second.report.issues.contains { $0.kind == .unknownProtocol && $0.item == "quantum" })
    }
}
