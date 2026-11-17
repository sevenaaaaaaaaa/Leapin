import XCTest
import LeapinCore
@testable import LeapinIntegrations

final class KernelProxyTests: XCTestCase {
    private let payload = """
    {"proxies":{
      "GLOBAL":{"type":"Selector","now":"HK 01","all":["DIRECT","HK 01"],"history":[]},
      "PROXY":{"type":"URLTest","now":"HK 01","all":["HK 01","JP 01"],"history":[]},
      "JP 01":{"type":"Vless","history":[{"time":"2026-11-17T09:00:00.000Z","delay":250}],"alive":true},
      "HK 01":{"type":"Shadowsocks","history":[{"time":"2026-11-17T09:59:00.000Z","delay":0},{"time":"2026-11-17T10:00:00.123Z","delay":88}],"alive":true},
      "DIRECT":{"type":"Direct","history":[],"alive":true}
    }}
    """

    func testParsesGroupsNodesAndHistory() throws {
        let proxies = try KernelProxy.parse(Data(payload.utf8))
        XCTAssertEqual(proxies.count, 5)

        let global = try XCTUnwrap(proxies.first { $0.name == "GLOBAL" })
        XCTAssertTrue(global.isGroup)
        XCTAssertTrue(global.isSelectable)
        XCTAssertEqual(global.selected, "HK 01")
        XCTAssertEqual(global.members, ["DIRECT", "HK 01"])

        let urlTest = try XCTUnwrap(proxies.first { $0.name == "PROXY" })
        XCTAssertTrue(urlTest.isGroup)
        XCTAssertFalse(urlTest.isSelectable, "url-test 组不接受手动切换")

        let hk = try XCTUnwrap(proxies.first { $0.name == "HK 01" })
        XCTAssertFalse(hk.isGroup)
        XCTAssertEqual(hk.latestLatencyMs, 88, "取最近一次成功的延迟，跳过 0")
        XCTAssertNotNil(hk.latestSampleAt)
        XCTAssertFalse(hk.lastTestFailed, "最近一次是成功")

        let direct = try XCTUnwrap(proxies.first { $0.name == "DIRECT" })
        XCTAssertTrue(direct.isBuiltin)
        XCTAssertNil(direct.latestLatencyMs)
    }

    func testOrderingPutsGlobalThenSelectorsThenNodesThenBuiltins() throws {
        let ordered = KernelProxy.ordered(try KernelProxy.parse(Data(payload.utf8)))
        XCTAssertEqual(ordered.map(\.name), ["GLOBAL", "PROXY", "HK 01", "JP 01", "DIRECT"])
    }

    func testRejectsUnexpectedShape() {
        XCTAssertThrowsError(try KernelProxy.parse(Data("{\"nope\":1}".utf8)))
        XCTAssertThrowsError(try KernelProxy.parse(Data("not json".utf8)))
    }

    func testKernelErrorMessageIsReadable() {
        XCTAssertEqual(ManagedMihomo.message(in: Data(#"{"message":"An error occurred in the delay test"}"#.utf8)),
                       "An error occurred in the delay test")
        XCTAssertNil(ManagedMihomo.message(in: Data("{}".utf8)))
        XCTAssertNil(ManagedMihomo.message(in: Data(#"{"message":"   "}"#.utf8)))
    }

    func testPathSegmentEncodesNamesWithSlashAndEmoji() throws {
        let segment = try XCTUnwrap(ManagedMihomo.pathSegment("🇭🇰香港 01 / 专线"))
        XCTAssertFalse(segment.contains("/"))
        XCTAssertFalse(segment.contains(" "))
        XCTAssertEqual(segment.removingPercentEncoding, "🇭🇰香港 01 / 专线")
    }
}
