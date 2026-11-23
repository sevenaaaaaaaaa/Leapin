import XCTest
import LeapinCore
@testable import LeapinRuntime

/// B-2：系统代理标志不能按入参写死。`SystemProxy.statusAsync()` 返回的是该服务
/// 「第一个已启用的代理」，所以「有代理开着」不等于「那一个是我们的」——机器上原有
/// 企业代理、或 `networksetup` 退出 0 却没生效时，标志跟着入参走就会让面板谎报
/// 「接管范围：系统代理」，实际直连。
///
/// 这些用例只碰纯函数，一次都不执行 `networksetup`。
@MainActor
final class SystemProxyFlagTests: XCTestCase {

    private let ourPort = 7890

    private func flag(running: Bool = true, enabled: Bool = true,
                      host: String = "127.0.0.1", port: Int? = nil) -> Bool {
        LeapinEngine.systemProxyIsOurs(running: running, enabled: enabled, host: host,
                                       port: port ?? ourPort, ourPort: ourPort)
    }

    func testFlagIsFalseWhileTheEngineIsNotRunning() {
        XCTAssertFalse(flag(running: false), "引擎没跑，系统代理开着一律不算我们接管")
    }

    func testFlagIsFalseForAProxyThatIsNotOurs() {
        XCTAssertFalse(flag(enabled: true, host: "10.0.0.5"))
        XCTAssertFalse(flag(enabled: true, host: "proxy.corp.example"))
    }

    func testFlagIsFalseOnAnotherPort() {
        XCTAssertFalse(flag(port: 8080))
    }

    func testFlagIsFalseWhenTheSystemProxyIsOff() {
        XCTAssertFalse(flag(enabled: false))
    }

    func testFlagIsTrueForOurLoopbackProxyWhileRunning() {
        XCTAssertTrue(flag())
        XCTAssertTrue(flag(host: "localhost"), "Status 可能把回环写成 localhost")
    }

    // MARK: - 回读失败的口径

    func testReadbackMismatchExplainsItself() throws {
        let message = try XCTUnwrap(
            LeapinEngine.systemProxyReadbackMessage(enabled: true, nowOurs: false, ourPort: ourPort))
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(message.contains("未接管"), "实际：" + message)
    }

    func testNoMessageWhenTheReadbackAgreesOrWeWereTurningItOff() {
        XCTAssertNil(LeapinEngine.systemProxyReadbackMessage(enabled: true, nowOurs: true, ourPort: ourPort))
        XCTAssertNil(LeapinEngine.systemProxyReadbackMessage(enabled: false, nowOurs: false, ourPort: ourPort),
                     "关闭方向不必报错")
    }
}
