import Foundation

// 书脊模型层的命令行自测。跑法（在仓库根目录）：
//
//   swiftc -O Sources/LeapinApp/Design/SpineModel.swift scripts/spine-selftest.swift \
//     -o /tmp/spine_selftest && /tmp/spine_selftest
//
// 只编模型文件，不编 SwiftUI：判断逻辑必须能脱离界面复跑。

@main
struct SpineSelfTest {
    static var pass = 0
    static var failures: [String] = []

    static func check(_ name: String, _ condition: Bool, _ note: String = "") {
        if condition {
            pass += 1
        } else {
            failures.append(note.isEmpty ? name : "\(name) — \(note)")
        }
    }

    static func main() {
        sourceLabels()
        shelfWidths()
        health()
        compare()
        hitTest()
        vertical()
        ruleLines()

        for line in failures { print("FAIL \(line)") }
        print("V6SPINE \(failures.isEmpty ? "PASS" : "FAIL") \(pass)/\(pass + failures.count)")
        if !failures.isEmpty { exit(1) }
    }

    // MARK: 来源

    static func sourceLabels() {
        check("nil → 本机", LPSpineSource.label(from: nil) == "本机")
        check("空白 → 本机", LPSpineSource.label(from: "   ") == "本机")
        check("订阅取主机", LPSpineSource.label(from: "https://sub.example.com/api/v1/client?token=abc") == "sub.example.com")
        check("文件取文件名", LPSpineSource.label(from: "/Users/me/Downloads/company.yaml") == "company.yaml")
        check("裸串原样", LPSpineSource.label(from: "粘贴的节点列表") == "粘贴的节点列表")
    }

    // MARK: 厚度

    static func shelfWidths() {
        check("空配置 52", LPSpineShelfLayout.width(ruleCount: 0) == 52)
        check("1 条最薄", LPSpineShelfLayout.width(ruleCount: 1) == 46)
        check("50 条最薄", LPSpineShelfLayout.width(ruleCount: 50) == 46)
        check("51 条进第二档", LPSpineShelfLayout.width(ruleCount: 51) == 54)
        check("500 条第二档", LPSpineShelfLayout.width(ruleCount: 500) == 54)
        check("501 条第三档", LPSpineShelfLayout.width(ruleCount: 501) == 62)
        check("5000 条第三档", LPSpineShelfLayout.width(ruleCount: 5_000) == 62)
        check("5001 条最厚", LPSpineShelfLayout.width(ruleCount: 5_001) == 70)
    }

    // MARK: 体检

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func spine(name: String = "样例",
                      rules: Int = 10,
                      updatedDaysAgo: Double = 0,
                      groups: [LPSpineGroup] = [LPSpineGroup(name: "Proxy", type: "select", memberCount: 3)],
                      outbounds: [String] = ["Proxy", "DIRECT", "REJECT"],
                      dnsPort: Int = 5354,
                      upstream: Int = 2,
                      adblock: Bool = false,
                      adblockLists: Int = 0,
                      dangling: [String] = [],
                      emptyGroups: [String] = []) -> LPSpineSnapshot {
        LPSpineSnapshot(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(max(1, abs(name.hashValue % 9)))")!,
                        name: name,
                        source: "本机",
                        updatedAt: now.addingTimeInterval(-updatedDaysAgo * 86_400),
                        ruleCount: rules,
                        groups: groups,
                        outbounds: outbounds,
                        adblockEnabled: adblock,
                        adblockListCount: adblockLists,
                        dnsPort: dnsPort,
                        dnsUpstreamCount: upstream,
                        danglingPolicies: dangling,
                        emptyGroups: emptyGroups)
    }

    static func health() {
        let ok = LPSpineHealth.evaluate(spine(), now: now)
        check("健康样本无 fail", ok.level == .ok, "level=\(ok.level)")
        check("健康样本结论", ok.label == "可以启用", ok.label)
        check("体检项数 7", ok.checks.count == 7, "\(ok.checks.count)")

        let empty = LPSpineHealth.evaluate(spine(rules: 0), now: now)
        check("无规则判 fail", empty.level == .fail)
        check("无规则结论", empty.label == "1 项需修复", empty.label)

        let dangling = LPSpineHealth.evaluate(spine(dangling: ["Proxy", "公司出口"]), now: now)
        check("悬空引用 fail", dangling.level == .fail)
        check("悬空引用写名字", dangling.checks.first { $0.name == "引用" }?.detail.contains("公司出口") == true)

        let emptyGroup = LPSpineHealth.evaluate(spine(emptyGroups: ["Fallback"]), now: now)
        check("空组 fail", emptyGroup.level == .fail)
        check("空组写名字", emptyGroup.checks.first { $0.name == "策略组" }?.detail.contains("Fallback") == true)

        let noOutbound = LPSpineHealth.evaluate(spine(outbounds: []), now: now)
        check("无出口 fail", noOutbound.level == .fail)

        let dnsZero = LPSpineHealth.evaluate(spine(dnsPort: 0), now: now)
        check("端口 0 fail", dnsZero.checks.first { $0.name == "DNS" }?.level == .fail)
        let dnsMdns = LPSpineHealth.evaluate(spine(dnsPort: 5353), now: now)
        check("5353 fail", dnsMdns.checks.first { $0.name == "DNS" }?.level == .fail)
        let noUpstream = LPSpineHealth.evaluate(spine(upstream: 0), now: now)
        check("无上游 warn", noUpstream.level == .warn)
        check("无上游结论", noUpstream.label == "1 项待处理", noUpstream.label)

        // 内置列表一直在，空的自加列表不该亮黄灯（否则每份导入的配置都带一条假警告）
        let adblock = LPSpineHealth.evaluate(spine(adblock: true, adblockLists: 0), now: now)
        check("去广告空列表 ok", adblock.checks.first { $0.name == "去广告" }?.level == .ok)
        check("去广告写内置", adblock.checks.first { $0.name == "去广告" }?.detail == "内置列表")
        let adblockOk = LPSpineHealth.evaluate(spine(adblock: true, adblockLists: 3), now: now)
        check("去广告有自加", adblockOk.checks.first { $0.name == "去广告" }?.detail == "内置列表 + 3 个自加")

        let stale = LPSpineHealth.evaluate(spine(updatedDaysAgo: 31), now: now)
        check("31 天 warn", stale.level == .warn)
        check("31 天写数字", stale.checks.first { $0.name == "更新" }?.detail == "31 天没更新")
        let today = LPSpineHealth.evaluate(spine(updatedDaysAgo: 0), now: now)
        check("今天更新", today.checks.first { $0.name == "更新" }?.detail == "今天更新过")
        let threeDays = LPSpineHealth.evaluate(spine(updatedDaysAgo: 3), now: now)
        check("3 天前更新", threeDays.checks.first { $0.name == "更新" }?.detail == "3 天前更新")
    }

    // MARK: 比较

    static func snap(_ id: String, _ name: String, _ rules: [String],
                     groups: [LPSpineGroup] = [], outbounds: [String] = []) -> LPSpineSnapshot {
        LPSpineSnapshot(id: UUID(uuidString: id)!,
                        name: name,
                        source: "本机",
                        updatedAt: now,
                        ruleCount: rules.count,
                        ruleLines: rules,
                        groups: groups,
                        outbounds: outbounds,
                        dnsPort: 5354,
                        dnsUpstreamCount: 1)
    }

    static func compare() {
        let a = snap("11111111-1111-1111-1111-111111111111", "公司", ["r1", "r2", "r3"],
                     groups: [LPSpineGroup(name: "公司", type: "select", memberCount: 2)],
                     outbounds: ["公司出口", "DIRECT"])
        let b = snap("22222222-2222-2222-2222-222222222222", "机场", ["r2", "r3", "r4", "r5"],
                     groups: [LPSpineGroup(name: "Proxy", type: "url-test", memberCount: 9)],
                     outbounds: ["Proxy", "DIRECT"])

        let diff = LPSpineCompare.run(a, b)
        check("共同规则 2 条", diff.commonRules == 2, "\(diff.commonRules)")
        check("左侧独有 r1", diff.onlyLeftRules == ["r1"], "\(diff.onlyLeftRules)")
        check("右侧独有 r4 r5", diff.onlyRightRules == ["r4", "r5"])
        check("总量差 1 条", diff.ruleDelta == 1, "\(diff.ruleDelta)")
        check("左侧独有组", diff.leftOnlyGroups == ["公司"])
        check("右侧独有组", diff.rightOnlyGroups == ["Proxy"])
        check("出口差集", diff.leftOnlyOutbounds == ["公司出口"] && diff.rightOnlyOutbounds == ["Proxy"])
        check("结论句话", diff.headline == "机场 比 公司 多 1 条（4 对 3）：右侧独有 2 条、左侧独有 1 条", diff.headline)

        let same = LPSpineCompare.run(a, a)
        check("自比无差异", same.identicalRules && same.commonRules == 3)
        check("自比结论", same.headline == "同一条书脊，没有可比较的差异", same.headline)

        let twin = snap("33333333-3333-3333-3333-333333333333", "副本", ["r1", "r2", "r3"],
                        groups: [LPSpineGroup(name: "公司", type: "select", memberCount: 2)])
        check("同规则不同 id 结论", LPSpineCompare.run(a, twin).headline == "两份配置的规则完全相同",
              LPSpineCompare.run(a, twin).headline)

        let fewer = LPSpineCompare.run(b, a)
        check("反向 少 1 条", fewer.ruleDelta == -1, "\(fewer.ruleDelta)")
        check("反向结论", fewer.headline.contains("少 1 条（3 对 4）"), fewer.headline)

        check("差集去重保序", LPSpineCompare.difference(["x", "y", "x"], ["y"]) == ["x"])
        check("差集空集", LPSpineCompare.difference(["x"], ["x"]).isEmpty)
    }

    // MARK: 落点

    static func hitTest() {
        let aID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let bID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        let frames: [UUID: CGRect] = [
            aID: CGRect(x: 0, y: 0, width: 46, height: 300),
            bID: CGRect(x: 58, y: 0, width: 62, height: 300),
        ]
        check("命中第二条", LPSpineHitTest.target(point: CGPoint(x: 90, y: 120), frames: frames, excluding: aID) == bID)
        check("拖自己不算落点", LPSpineHitTest.target(point: CGPoint(x: 20, y: 120), frames: frames, excluding: aID) == nil)
        check("缝里不算落点", LPSpineHitTest.target(point: CGPoint(x: 52, y: 120), frames: frames, excluding: aID) == nil)
        check("边缘 3pt 内不算", LPSpineHitTest.target(point: CGPoint(x: 60, y: 120), frames: frames, excluding: aID) == nil,
              "inset 后应落在框外")
        check("边缘 6pt 算", LPSpineHitTest.target(point: CGPoint(x: 63, y: 120), frames: frames, excluding: aID) == bID)
        check("框外不算", LPSpineHitTest.target(point: CGPoint(x: 400, y: 120), frames: frames, excluding: nil) == nil)
        check("纵向出界不算", LPSpineHitTest.target(point: CGPoint(x: 90, y: 320), frames: frames, excluding: nil) == nil)
    }

    // MARK: 竖排

    static func vertical() {
        check("中文名竖立", LPSpineVertical.mode(for: "公司直连") == .stacked)
        check("机场竖立", LPSpineVertical.mode(for: "机场主订阅") == .stacked)
        check("英文名转排", LPSpineVertical.mode(for: "Tokyo") == .rotated)
        check("带横线转排", LPSpineVertical.mode(for: "Office-HK") == .rotated)
        check("文件名转排", LPSpineVertical.mode(for: "家庭网络.yaml") == .rotated)
        check("空串转排", LPSpineVertical.mode(for: "") == .rotated)
        check("超长中文转排", LPSpineVertical.mode(for: "一二三四五六七八九十一二三") == .rotated)

        check("容量 176/12", LPSpineVertical.capacity(length: 176, size: 12) == 12,
              "\(LPSpineVertical.capacity(length: 176, size: 12))")
        check("不放截断", LPSpineVertical.stacked("公司直连", capacity: 12) == "公司直连")
        check("放不下补省略号", LPSpineVertical.stacked("一二三四五六七八", capacity: 5) == "一二三四…",
              LPSpineVertical.stacked("一二三四五六七八", capacity: 5))
        check("一格只剩省略号", LPSpineVertical.stacked("一二三", capacity: 1) == "")
    }

    // MARK: 规则行

    static func ruleLines() {
        let shown = LPSpineRuleLine.display(kind: "DOMAIN-SUFFIX", value: "google.com", policy: "Proxy")
        check("显示形态", shown == "DOMAIN-SUFFIX,google.com → Proxy", shown)
    }
}
