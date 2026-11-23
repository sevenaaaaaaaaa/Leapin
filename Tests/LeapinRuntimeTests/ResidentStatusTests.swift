import XCTest
import LeapinCore
@testable import LeapinRuntime

/// 常驻层只有一个状态源：菜单栏面板与实时浮窗都读 `ResidentStatus`。
/// 这些用例锁住三件事：速率只差分一次、三种 ink（正常/降级/异常）由真实事件决定、
/// §2.5 的接管范围那一行说真话。
final class ResidentStatusTests: XCTestCase {

    private func flow(_ host: String, policy: String = "PROXY", blockedBy: String? = nil) -> FlowEvent {
        FlowEvent(phase: .opened, host: host, port: 443, policy: policy, blockedBy: blockedBy)
    }

    private func input(
        state: EngineState = .running,
        stats: EngineStats = EngineStats(),
        traffic: ResidentTrafficSample = ResidentTrafficSample(),
        flows: [FlowEvent] = [],
        coverage: ResidentCoverage = ResidentCoverage(scope: .systemProxy),
        profileName: String = "海外",
        mode: String? = nil,
        exit: String? = "HK 01",
        exitGroup: String? = "GLOBAL",
        lastError: String? = nil,
        scriptIssues: [String: String] = [:],
        activeConnections: Int = 0
    ) -> ResidentStatusInput {
        ResidentStatusInput(state: state, stats: stats, traffic: traffic, flows: flows,
                            coverage: coverage, profileName: profileName, mode: mode,
                            exit: exit, exitGroup: exitGroup, lastError: lastError,
                            scriptIssues: scriptIssues, activeConnections: activeConnections)
    }

    // MARK: - 五种输入

    /// 1. 空闲：没有接管，也没有异常可说。
    func testIdleStatusSaysStoppedAndClaimsNoCoverage() {
        let status = ResidentStatus.make(input(state: .stopped,
                                               coverage: .init(scope: .none),
                                               profileName: "直连",
                                               exit: nil, exitGroup: nil),
                                         rates: .zero)
        XCTAssertEqual(status.tone, .idle)
        XCTAssertEqual(status.title, "代理未运行")
        XCTAssertEqual(status.subtitle, "直连")
        XCTAssertEqual(status.rates, .zero)
        XCTAssertEqual(status.blocked, 0)
        XCTAssertEqual(status.coverage.declaration, "接管范围：未接管 · 所有进程都绕过")
        XCTAssertTrue(status.issues.isEmpty, "停着的时候「未接管」是事实而不是异常")
        XCTAssertFalse(status.needsAttention)
    }

    /// 2. 运行中：一条路、一个速率、一个拦截数。
    func testRunningStatusCarriesOneRouterDecision() {
        var stats = EngineStats()
        stats.blocked = 7
        stats.requests = 42
        let status = ResidentStatus.make(input(stats: stats, activeConnections: 3),
                                         rates: ResidentRates(down: 1_200_000, up: 12_000))
        XCTAssertEqual(status.tone, .normal)
        XCTAssertEqual(status.title, "运行中 · 规则分流")
        XCTAssertEqual(status.subtitle, "海外 · GLOBAL › HK 01")
        XCTAssertEqual(status.exit, "HK 01")
        XCTAssertEqual(status.profileName, "海外")
        XCTAssertEqual(status.blocked, 7)
        XCTAssertEqual(status.connections, 3)
        XCTAssertEqual(status.coverage.declaration, "接管范围：系统代理 · 部分进程未覆盖")
        XCTAssertTrue(status.issues.isEmpty)
        XCTAssertFalse(status.needsAttention)
    }

    func testRunningMihomoStatusNamesTheKernelMode() {
        let status = ResidentStatus.make(input(mode: "rule"), rates: .zero)
        XCTAssertEqual(status.title, "运行中 · 规则模式")
        XCTAssertEqual(status.tone, .normal)
    }

    /// 3. 脚本降级：引擎还在跑，但一条脚本已经不再生效。
    func testScriptDegradationTurnsTheInkHalfRed() {
        let status = ResidentStatus.make(input(scriptIssues: ["geo.js": "超时 120ms"]), rates: .zero)
        XCTAssertEqual(status.tone, .degraded)
        XCTAssertTrue(status.needsAttention)
        XCTAssertEqual(status.issues.map(\.text), ["脚本降级：geo.js — 超时 120ms"])
        XCTAssertEqual(status.issues.first?.severity, .degraded)
        XCTAssertEqual(status.title, "运行中 · 规则分流", "降级仍然是一份在跑的状态，标题不改口")
    }

    func testSeveralDegradedScriptsShareOneLineSortedByName() {
        let status = ResidentStatus.make(input(scriptIssues: ["b.js": "抛错", "a.js": "超时"]), rates: .zero)
        XCTAssertEqual(status.issues.map(\.text), ["脚本降级：2 个脚本已停用（a.js、b.js）"])
    }

    /// 4. 引擎失败：这是红色，不是半红。
    func testEngineFailureTurnsTheInkRed() {
        let status = ResidentStatus.make(input(state: .failed("端口 7890 被占用"),
                                               exit: nil, exitGroup: nil,
                                               lastError: "端口 7890 被占用"),
                                         rates: .zero)
        XCTAssertEqual(status.tone, .failed)
        XCTAssertEqual(status.title, "代理出错")
        XCTAssertEqual(status.subtitle, "海外")
        XCTAssertEqual(status.issues.map(\.text), ["端口 7890 被占用"], "同一个原因只说一次")
        XCTAssertEqual(status.issues.first?.severity, .failure)
        XCTAssertTrue(status.needsAttention)
    }

    /// 运行中残留的错误是降级，不是失败：流量还在走。
    func testErrorWhileStillRunningIsDegradation() {
        let status = ResidentStatus.make(input(lastError: "DNS 端口 5354 未启动"), rates: .zero)
        XCTAssertEqual(status.tone, .degraded)
        XCTAssertEqual(status.issues.map(\.text), ["DNS 端口 5354 未启动"])
    }

    /// 5. 有未覆盖声明：这是事实，不是警告 —— ink 保持正常。
    func testUncoveredProcessesAreAFactNotAWarning() {
        let counted = ResidentStatus.make(input(coverage: .init(scope: .systemProxy, uncoveredProcesses: 3)),
                                          rates: .zero)
        XCTAssertEqual(counted.tone, .normal)
        XCTAssertTrue(counted.issues.isEmpty, "§2.5 的一行事实不进「异常」块")
        XCTAssertEqual(counted.coverage.declaration, "接管范围：系统代理 · 有 3 个进程未覆盖")

        let unknown = ResidentStatus.make(input(coverage: .init(scope: .systemProxy, uncoveredProcesses: nil)),
                                          rates: .zero)
        XCTAssertEqual(unknown.coverage.declaration, "接管范围：系统代理 · 部分进程未覆盖")

        let none = ResidentStatus.make(input(coverage: .init(scope: .systemProxy, uncoveredProcesses: 0)),
                                       rates: .zero)
        XCTAssertEqual(none.coverage.declaration, "接管范围：系统代理 · 未检测到绕过进程")
    }

    func testRunningWithoutSystemProxyIsDegraded() {
        let status = ResidentStatus.make(input(coverage: .init(scope: .none)), rates: .zero)
        XCTAssertEqual(status.tone, .degraded)
        XCTAssertEqual(status.issues.map(\.text), ["系统代理未接管，所有进程都绕过 Leapin"])
        XCTAssertEqual(status.coverage.declaration, "接管范围：未接管 · 所有进程都绕过")
    }

    // MARK: - 速率只差分一次

    func testRateMeterDiffsOnceAndIgnoresSamplesInsideTheSameWindow() {
        var meter = ResidentRateMeter()
        let t0 = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(meter.sample(.init(bytesIn: 0, bytesOut: 0, at: t0)), .zero, "第一帧只能定基准")

        let first = meter.sample(.init(bytesIn: 1_000, bytesOut: 2_000_000, at: t0.addingTimeInterval(1)))
        XCTAssertEqual(first.up, 1_000, accuracy: 0.001)
        XCTAssertEqual(first.down, 2_000_000, accuracy: 0.001)

        // 0.2s 后的第二次采样落在同一个 1s 窗口里：不得把上一段字节再算一遍。
        let second = meter.sample(.init(bytesIn: 1_200, bytesOut: 2_400_000, at: t0.addingTimeInterval(1.2)))
        XCTAssertEqual(second, first, "窗口不到一半就再来一帧，速率必须保持不变")

        // 窗口满了，才用 1.0s 那一帧做差分。
        let third = meter.sample(.init(bytesIn: 2_000, bytesOut: 3_000_000, at: t0.addingTimeInterval(2)))
        XCTAssertEqual(third.up, 1_000, accuracy: 0.001)
        XCTAssertEqual(third.down, 1_000_000, accuracy: 0.001)
    }

    func testRateMeterClampsCounterResetsToZero() {
        var meter = ResidentRateMeter()
        let t0 = Date(timeIntervalSince1970: 2_000)
        _ = meter.sample(.init(bytesIn: 9_000, bytesOut: 9_000, at: t0))
        let after = meter.sample(.init(bytesIn: 10, bytesOut: 10, at: t0.addingTimeInterval(1)))
        XCTAssertEqual(after, .zero, "重启后计数器归零，速率不能变成负数")
    }

    func testRateFormattingMatchesTheSurfaces() {
        XCTAssertEqual(ResidentRates(down: 0, up: 0).downText, "0 B/s")
        XCTAssertEqual(ResidentRates(down: 512, up: 0).downText, "512 B/s")
        XCTAssertEqual(ResidentRates(down: 1_536, up: 0).downText, "1.5 KB/s")
        XCTAssertEqual(ResidentRates(down: 2_000_000, up: 1_536).summary, "↓ 1.9 MB/s · ↑ 1.5 KB/s")
    }

    // MARK: - 最近连接

    func testRecentFlowsAreTheNewestThreeWithOneVocabulary() {
        let flows = [flow("a.example.com"),
                     flow("b.example.com", policy: "DIRECT"),
                     flow("c.example.com", blockedBy: "adblock"),
                     flow("d.example.com", policy: "")]
        let status = ResidentStatus.make(input(flows: flows), rates: .zero)
        XCTAssertEqual(status.recent.map(\.host), ["d.example.com", "c.example.com", "b.example.com"])
        XCTAssertEqual(status.recent.map(\.label), ["—", "拦截", "DIRECT"])
        XCTAssertEqual(status.recent.map(\.kind), [.other, .blocked, .direct])
        XCTAssertTrue(status.recent.allSatisfy { brief in
            flows.contains { $0.id == brief.id && $0.host == brief.host }
        }, "行的身份来自 FlowEvent，视图不能自己造 id")
    }

    // MARK: - 一个状态源

    @MainActor
    func testStorePublishesOneStatusForEverySurface() {
        let store = ResidentStatusStore(status: .empty)
        let t0 = Date(timeIntervalSince1970: 3_000)

        let menuBar = store.update(input(traffic: .init(bytesIn: 0, bytesOut: 0, at: t0)))
        XCTAssertEqual(menuBar, store.status)

        // 浮窗在同一秒里再采一帧：读到的必须是同一份，数字不会变成两个。
        let floating = store.update(input(traffic: .init(bytesIn: 4_000, bytesOut: 8_000, at: t0.addingTimeInterval(0.2))))
        XCTAssertEqual(floating, menuBar)
        XCTAssertEqual(store.status, menuBar)
        XCTAssertEqual(menuBar.rates, .zero, "窗口未到一半，速率还没资格更新")
    }

    @MainActor
    func testStoreKeepsTheExitThePanelLearned() {
        let store = ResidentStatusStore(status: .empty)
        store.rememberExit(snapshot: MenuBarSnapshot(kernel: .native, running: true,
                                                     current: "HK 01", currentGroup: "GLOBAL"))
        let status = store.update(input(exit: nil, exitGroup: nil))
        XCTAssertEqual(status.subtitle, "海外 · GLOBAL › HK 01", "浮窗不必自己再取一次快照")
    }
}
