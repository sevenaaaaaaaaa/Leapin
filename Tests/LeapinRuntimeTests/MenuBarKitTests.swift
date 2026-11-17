import XCTest
import LeapinCore
import LeapinControl
@testable import LeapinRuntime

final class MenuBarKitTests: XCTestCase {
    // MARK: Pure helpers

    func testLatencyToneThresholds() {
        XCTAssertEqual(LatencyTone.of(0), .fast)
        XCTAssertEqual(LatencyTone.of(199), .fast)
        XCTAssertEqual(LatencyTone.of(200), .ok)
        XCTAssertEqual(LatencyTone.of(800), .ok)
        XCTAssertEqual(LatencyTone.of(801), .slow)
        XCTAssertEqual(LatencyTone.of(nil), .unknown)
        XCTAssertEqual(LatencyTone.of(nil, failed: true), .failed)
        XCTAssertEqual(LatencyTone.of(87, failed: true), .fast, "有数值就以数值为准")
    }

    func testLatencyText() {
        XCTAssertEqual(MenuBarKit.latencyText(87), "87 ms")
        XCTAssertEqual(MenuBarKit.latencyText(nil), "未测")
        XCTAssertEqual(MenuBarKit.latencyText(nil, failed: true), "失败")
    }

    func testBestSkipsFailedAndNonDialableNodes() {
        let nodes = [
            MenuBarNode(name: "A", latencyMs: nil, failed: true),
            MenuBarNode(name: "B", latencyMs: 240),
            MenuBarNode(name: "C", latencyMs: 61),
            MenuBarNode(name: "DIRECT", latencyMs: 12, dialable: false),
            MenuBarNode(name: "D", latencyMs: 0),
        ]
        XCTAssertEqual(MenuBarKit.best(in: nodes), MenuBarBest(name: "C", latencyMs: 61))
        XCTAssertNil(MenuBarKit.best(in: []))
        XCTAssertNil(MenuBarKit.best(in: [MenuBarNode(name: "A", latencyMs: nil)]))
    }

    func testSearchMatchesNamesCaseAndSymbolInsensitively() {
        XCTAssertTrue(MenuBarKit.matches("🇭🇰香港 01 | 专线", query: "香港"))
        XCTAssertTrue(MenuBarKit.matches("HK-01", query: "hk"))
        XCTAssertTrue(MenuBarKit.matches("anything", query: "  "), "空查询等于不过滤")
        XCTAssertFalse(MenuBarKit.matches("HK-01", query: "日本"))

        let group = MenuBarGroup(name: "PROXY", type: "select", selected: "HK-01",
                                 members: [MenuBarNode(name: "HK-01"), MenuBarNode(name: "JP-02")],
                                 selectable: true)
        XCTAssertEqual(MenuBarKit.filtered(group, query: "jp").members.map(\.name), ["JP-02"])
        XCTAssertEqual(MenuBarKit.filtered(group, query: "").members.count, 2)
    }

    func testSummaryReadsLikeTheMenuBarRow() {
        let running = MenuBarSnapshot(kernel: .native, running: true, groups: [],
                                      current: "HK 01", currentGroup: "PROXY", currentLatencyMs: 87)
        XCTAssertEqual(MenuBarKit.summary(running), "PROXY › HK 01 · 87 ms")

        var withoutLatency = running
        withoutLatency.currentLatencyMs = nil
        XCTAssertEqual(MenuBarKit.summary(withoutLatency), "PROXY › HK 01")

        var stopped = running
        stopped.running = false
        XCTAssertEqual(MenuBarKit.summary(stopped), "代理未运行")

        var empty = running
        empty.current = nil
        empty.note = "这份配置没有策略组"
        XCTAssertEqual(MenuBarKit.summary(empty), "这份配置没有策略组")
    }

    func testModeTitle() {
        XCTAssertEqual(MenuBarKit.modeTitle("global"), "全局模式")
        XCTAssertEqual(MenuBarKit.modeTitle("rule"), "规则模式")
        XCTAssertEqual(MenuBarKit.modeTitle("direct"), "直连模式")
        XCTAssertEqual(MenuBarKit.modeTitle(nil), "内核模式")
    }

    @MainActor
    func testStatusBadgePrefersTheQuickResult() {
        let status = MenuBarStatus()
        XCTAssertNil(status.badge)
        status.best = MenuBarBest(name: "B", latencyMs: 40)
        XCTAssertEqual(status.badge, "40")
        status.current = MenuBarTestOutcome(name: "A", latencyMs: 91)
        XCTAssertEqual(status.badge, "91")
        status.pending = 3
        XCTAssertNil(status.badge, "测速进行中不显示旧数字")
        status.pending = 0
        status.reset()
        XCTAssertNil(status.badge)
    }

    // MARK: Engine snapshot

    private func temporaryStore() throws -> ProfileStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ProfileStore(root: root)
    }

    @MainActor
    private func makeEngine(withGroups: Bool = true) throws -> LeapinEngine {
        let store = try temporaryStore()
        let outbounds: [OutboundConfig] = [
            .direct, .reject,
            OutboundConfig(name: "HK 01", type: .shadowsocks, host: "192.0.2.10", port: 8388),
            OutboundConfig(name: "JP 01", type: .shadowsocks, host: "192.0.2.11", port: 8388),
        ]
        let groups: [PolicyGroup] = withGroups ? [
            PolicyGroup(name: "PROXY", type: .select, proxies: ["HK 01", "JP 01", "DIRECT"], selected: "JP 01"),
            PolicyGroup(name: "AUTO", type: .urlTest, proxies: ["HK 01", "JP 01"], selected: "HK 01"),
        ] : []
        let profile = Profile(name: "Menu",
                              general: GeneralConfig(mixedPort: 7890, httpPort: 0, socksPort: 0,
                                                     captureEnabled: false, dnsHijack: false,
                                                     controlEnabled: false),
                              outbounds: outbounds, groups: groups,
                              rules: [Rule(kind: .match, value: "", policy: "PROXY")])
        _ = try store.save(profile)
        store.activeProfileID = profile.id
        return LeapinEngine(store: store)
    }

    @MainActor
    func testSnapshotCarriesGroupsCurrentNodeAndProfiles() async throws {
        let engine = try makeEngine()
        let snapshot = await engine.menuBarSnapshot()

        XCTAssertEqual(snapshot.kernel, .native)
        XCTAssertFalse(snapshot.running)
        XCTAssertEqual(snapshot.currentGroup, "PROXY")
        XCTAssertEqual(snapshot.current, "JP 01")
        XCTAssertEqual(snapshot.switchableGroups.map(\.name), ["PROXY"],
                       "url-test 组不能手动切换")
        XCTAssertEqual(snapshot.groups.count, 2)
        XCTAssertEqual(snapshot.groups.first?.members.map(\.name), ["HK 01", "JP 01", "DIRECT"])
        XCTAssertEqual(snapshot.profiles.count, 1)
        XCTAssertEqual(snapshot.activeProfile, engine.profile.id)
        XCTAssertEqual(snapshot.profiles.first?.kernel, .native)
    }

    @MainActor
    func testSnapshotWithoutGroupsSaysWhyItIsEmpty() async throws {
        let engine = try makeEngine(withGroups: false)
        let snapshot = await engine.menuBarSnapshot()
        XCTAssertTrue(snapshot.groups.isEmpty)
        XCTAssertNil(snapshot.current)
        XCTAssertEqual(snapshot.note, "这份配置没有策略组")
    }

    @MainActor
    func testSelectingANodeFromTheMenuBarUpdatesTheProfile() async throws {
        let engine = try makeEngine()
        try await engine.menuBarSelect(group: "PROXY", member: "HK 01")
        XCTAssertEqual(engine.profile.groups.first { $0.name == "PROXY" }?.selected, "HK 01")

        let snapshot = await engine.menuBarSnapshot()
        XCTAssertEqual(snapshot.current, "HK 01")
    }

    @MainActor
    func testQuickTestRefusesWhileStopped() async throws {
        let engine = try makeEngine()
        let outcome = await engine.menuBarQuickTest()
        XCTAssertNil(outcome.latencyMs)
        XCTAssertEqual(outcome.error, "代理未运行")
    }

    @MainActor
    func testSwitchToTheSameProfileWhileStoppedIsANoOp() async throws {
        let engine = try makeEngine()
        let before = engine.profile.id
        await engine.menuBarSwitch(profile: before)
        XCTAssertEqual(engine.profile.id, before)
    }

    func testFinalPolicyReadsTheLastMatchRule() {
        let clash = """
        rules:
          - DOMAIN-SUFFIX,apple.com,DIRECT
          - GEOIP,CN,DIRECT
          - MATCH,PROXY
        """
        XCTAssertEqual(MenuBarKit.finalPolicy(in: clash), "PROXY")

        let final = "rules:\n  - MATCH,DIRECT\n  - FINAL,REJECT   # last one wins"
        XCTAssertEqual(MenuBarKit.finalPolicy(in: final), "REJECT")
        XCTAssertNil(MenuBarKit.finalPolicy(in: "rules:\n  - DOMAIN,example.com,DIRECT"))
    }
}
