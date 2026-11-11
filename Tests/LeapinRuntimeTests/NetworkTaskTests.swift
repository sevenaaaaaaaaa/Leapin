import XCTest
import LeapinCore
import LeapinPolicy
@testable import LeapinRuntime

final class NetworkTaskTests: XCTestCase {
    func testPastedLinksDiscardSensitivePathsAndTokens() throws {
        let target = try XCTUnwrap(SiteTarget("https://EXAMPLE.com/account?token=secret#session"))
        XCTAssertEqual(target.host, "example.com")
        XCTAssertEqual(target.origin, "https://example.com/")
        XCTAssertEqual(target.port, 443)
    }

    func testTargetValidationDoesNotInterpretInstructionsAsHosts() {
        for input in ["", "让所有 App 都直连", "example.com other.com", "file:///etc/hosts",
                      "https://name:password@example.com", "https://example.com:0", "https://example.com:65536",
                      "https://example.com:abc", "example..com", "https://-example.com", "https://example.com\\@other.com"] {
            XCTAssertNil(SiteTarget(input), input)
        }
        XCTAssertEqual(NetworkTask.parse("帮我自动挑最快的节点"), .unsupported)
        XCTAssertEqual(NetworkTask.parse("让 example.com 和 other.com 直连"), .unsupported)
    }

    func testTargetsKeepExplicitSchemeAndPort() throws {
        let target = try XCTUnwrap(SiteTarget("http://192.0.2.1:8080/folder"))
        XCTAssertEqual(target.origin, "http://192.0.2.1:8080/")
        XCTAssertEqual(target.port, 8080)
        XCTAssertEqual(SiteTarget("example.com")?.origin, "https://example.com/")
        XCTAssertEqual(SiteTarget("localhost:8080")?.port, 8080)
    }

    func testExplicitTaskParsing() throws {
        let site = try XCTUnwrap(SiteTarget("example.com"))
        XCTAssertEqual(NetworkTask.parse("诊断 example.com"), .inspect(site))
        XCTAssertEqual(NetworkTask.parse("让 example.com 直连"), .direct(site))
        XCTAssertEqual(NetworkTask.parse("访问家里的文件"), .nas)
        XCTAssertEqual(NetworkTask.parse("为 App 安排网络"), .learn)
        XCTAssertEqual(NetworkTask.parse("导入配置"), .importProfile)
        XCTAssertEqual(NetworkTask.parse("公司内网"), .company)
        XCTAssertEqual(NetworkTask.parse("分享本地服务"), .shareService)
        XCTAssertEqual(NetworkTask.parse("工具与致谢"), .toolCredits)
        XCTAssertEqual(NetworkTask.parse("回家"), .home)
        XCTAssertEqual(NetworkTask.parse("Tailscale 回家"), .home)
    }

    func testDirectPlanWinsBeforeCatchAllAndDoesNotAffectSubdomains() throws {
        let original = Profile(name: "Test", rules: [Rule(kind: .match, value: "", policy: "REJECT")])
        let change = NetworkRuleChange(profile: original, target: try XCTUnwrap(SiteTarget("example.com")))
        var next = original
        next.rules = change.after
        let router = RuleEngine(profile: next)
        XCTAssertEqual(router.decide(ConnectionMeta(host: "example.com", port: 443)).policy, "DIRECT")
        XCTAssertTrue(router.decide(ConnectionMeta(host: "sub.example.com", port: 443)).isBlocked)
        XCTAssertEqual(Array(change.after.dropFirst()), original.rules)
    }

    func testUndoDetectsRuleEditsAndProfileSwitchButPreservesOtherSettings() throws {
        var profile = Profile(name: "Test", rules: [Rule(kind: .match, value: "", policy: "DIRECT")])
        let change = NetworkRuleChange(profile: profile, target: try XCTUnwrap(SiteTarget("example.com")))
        profile.rules = change.after
        XCTAssertTrue(change.canUndo(in: profile))
        profile.dns.listenPort = 15354
        XCTAssertTrue(change.canUndo(in: profile))
        profile.rules.append(Rule(kind: .domain, value: "other.com", policy: "DIRECT"))
        XCTAssertFalse(change.canUndo(in: profile))
        profile.rules = change.after
        profile.id = UUID()
        XCTAssertFalse(change.canUndo(in: profile))
    }

    func testRepeatedDirectPlanDoesNotAccumulateDuplicateRules() throws {
        let target = try XCTUnwrap(SiteTarget("example.com"))
        var profile = Profile(name: "Test")
        profile.rules = NetworkRuleChange(profile: profile, target: target).after
        let second = NetworkRuleChange(profile: profile, target: target)
        XCTAssertEqual(second.after.count, 1)
        XCTAssertEqual(second.before, second.after)
    }
}
