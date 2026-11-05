import XCTest
import Foundation
@testable import TouchFlowPolicy
import TouchFlowCore

/// 网络拦截表导出：hosts / ABP / Clash rule-set。
/// 重点不是"能生成字符串"，而是"只导出 REJECT、不把 DIRECT 洗成拦截"。
final class ExportFormatTests: XCTestCase {

    private func profile(rules: [Rule]) -> Profile {
        var p = Profile(
            name: "导出测试",
            general: GeneralConfig(),
            dns: DNSConfig(),
            adblock: AdBlockConfig(),
            outbounds: [.direct, .reject],
            groups: [
                PolicyGroup(name: "PROXY", type: .select, proxies: ["DIRECT"], selected: "DIRECT"),
                PolicyGroup(name: "ADBLOCK", type: .reject, proxies: []),
            ],
            rules: rules
        )
        p.rules = rules
        return p
    }

    func testHostsExportsOnlyRejectExactDomains() {
        let p = profile(rules: [
            Rule(kind: .domain, value: "ads.example.com", policy: "REJECT"),
            Rule(kind: .domain, value: "kept.example.com", policy: "PROXY"),
            Rule(kind: .domain, value: "grouped.example.com", policy: "ADBLOCK"),
            Rule(kind: .domainSuffix, value: "tracker.test", policy: "REJECT"),
            Rule(kind: .match, value: "", policy: "PROXY"),
        ])
        let text = ProfileExporter.hosts(p)
        XCTAssertTrue(text.contains("0.0.0.0 ads.example.com"))
        XCTAssertTrue(text.contains("0.0.0.0 grouped.example.com"), "reject 策略组也必须算拦截")
        XCTAssertFalse(text.contains("kept.example.com"), "PROXY 规则不得写进 hosts")
        XCTAssertFalse(text.contains("tracker.test"), "hosts 无法表达后缀，宁可不出也不误拦")
        XCTAssertTrue(text.contains("无法用 hosts 表达"), "被跳过的规则必须显式告知")
    }

    func testABPTranslatesSuffixToDomainAnchor() {
        let p = profile(rules: [
            Rule(kind: .domainSuffix, value: "doubleclick.net", policy: "REJECT"),
            Rule(kind: .domainKeyword, value: "adserver", policy: "ADBLOCK"),
            Rule(kind: .processName, value: "ssh", policy: "DIRECT"),
        ])
        let text = ProfileExporter.abp(p)
        XCTAssertTrue(text.contains("||doubleclick.net^"))
        XCTAssertTrue(text.contains("/adserver/"))
        XCTAssertFalse(text.contains("ssh"), "进程规则不属于 ABP 表达范围")
        XCTAssertTrue(text.hasPrefix("! Title:"))
    }

    func testRuleSetKeepsPayloadAndSkipsComposites() {
        let p = profile(rules: [
            Rule(kind: .domainSuffix, value: "ads.example", policy: "REJECT"),
            Rule(kind: .ipCIDR, value: "10.0.0.0/8", policy: "DIRECT"),
            Rule(kind: .processName, value: "ssh", policy: "DIRECT"),
            Rule(kind: .match, value: "", policy: "PROXY"),
        ])
        let text = ProfileExporter.ruleSet(p)
        XCTAssertTrue(text.hasPrefix("payload:"))
        XCTAssertTrue(text.contains("  - DOMAIN-SUFFIX,ads.example,REJECT"))
        XCTAssertTrue(text.contains("  - IP-CIDR,10.0.0.0/8,DIRECT"))
        XCTAssertFalse(text.contains("PROCESS-NAME"), "rule-set 不导出进程规则")
        XCTAssertFalse(text.contains("MATCH"), "MATCH 是 profile 级兜底，不属于 rule-set")
    }

    func testUnknownPolicyIsNotTreatedAsReject() {
        let p = profile(rules: [
            Rule(kind: .domain, value: "x.example", policy: "不存在的策略组"),
        ])
        XCTAssertFalse(ProfileExporter.isRejectPolicy("不存在的策略组", in: p),
                       "未定义的策略名不能默认按拦截导出")
        XCTAssertFalse(ProfileExporter.hosts(p).contains("x.example"))
    }

    func testHostsOutputIsLoadableHostsSyntax() {
        let p = profile(rules: [Rule(kind: .domain, value: "ads.example.com", policy: "REJECT")])
        let lines = ProfileExporter.hosts(p)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("0.0.0.0 "))
        XCTAssertEqual(lines[0].components(separatedBy: " ").count, 2, "hosts 每行必须是 IP + 主机名两个字段")
    }
}
