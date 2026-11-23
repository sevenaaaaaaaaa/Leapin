import XCTest
import LeapinCore
@testable import LeapinRuntime

/// 常驻层把 `lastError` 当成「当前异常」渲染（`ResidentStatus.make`），所以
/// `toggleSystemProxy` 成功一次就必须把它清掉；留着上一条会让面板与浮窗长期停在
/// 「降级」，直到下一次 start / activate。
///
/// `SystemProxy` 是静态真实命令，这些用例一次都不执行 `networksetup`：
/// 成功分支的记账走 `applySystemProxySuccess`（internal 接缝），失败分支走引擎
/// 未运行时的 guard —— 它在任何命令之前就抛出。
@MainActor
final class SystemProxyErrorTests: XCTestCase {

    private func temporaryStore() throws -> ProfileStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ProfileStore(root: root)
    }

    private func makeEngine() throws -> LeapinEngine {
        let store = try temporaryStore()
        let profile = Profile(name: "SysProxy",
                              general: GeneralConfig(mixedPort: 7890, httpPort: 0, socksPort: 0,
                                                     captureEnabled: false, dnsHijack: false,
                                                     controlEnabled: false),
                              rules: [Rule(kind: .match, value: "", policy: "DIRECT")])
        _ = try store.save(profile)
        store.activeProfileID = profile.id
        return LeapinEngine(store: store)
    }

    /// T-01 评审的复现序列：失败一次留下错误，随后成功一次，错误必须消失。
    func testSuccessClearsTheErrorLeftByAFailedAttempt() async throws {
        let engine = try makeEngine()

        // 引擎未运行：enableSystemProxy 的第一道 guard 直接抛错，不碰 networksetup。
        await engine.toggleSystemProxy(true)
        XCTAssertNotNil(engine.lastError, "失败路径照旧写入 lastError")
        XCTAssertFalse(engine.systemProxyActive)

        engine.applySystemProxySuccess(true)
        XCTAssertNil(engine.lastError, "成功切换后不接受上一条失败的残留")
        XCTAssertTrue(engine.systemProxyActive, "标志跟着事实走")
    }

    /// 关闭方向同样要清：成功的 disable 也是一次「当前没有异常」。
    func testDisablingAlsoClearsAStaleError() throws {
        let engine = try makeEngine()
        engine.systemProxyActive = true
        engine.lastError = "上一次开启失败：networksetup 报错"

        engine.applySystemProxySuccess(false)
        XCTAssertNil(engine.lastError)
        XCTAssertFalse(engine.systemProxyActive)
    }

    /// 失败路径保持原样：写错误、不动标志、不把错误吞掉。
    func testFailedAttemptStillReportsAndLeavesTheFlagAlone() async throws {
        let engine = try makeEngine()
        engine.lastError = "旧错误"
        engine.systemProxyActive = false

        await engine.toggleSystemProxy(true)

        let message = engine.lastError ?? ""
        XCTAssertTrue(message.contains("代理尚未运行"), "实际：" + message)
        XCTAssertFalse(engine.systemProxyActive)
    }
}
