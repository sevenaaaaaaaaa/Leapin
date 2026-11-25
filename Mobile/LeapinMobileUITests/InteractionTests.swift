import XCTest

/// v6 的交互验证：每个测试都对准一个「不是画出来的」行为。
/// 这三个用例是设计文档第 7 节验收清单的机器版本。
final class InteractionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    /// 编排：点一次 S/M/L，标签必须真的变。
    func testComposeChangesCardSpan() {
        let app = launch()
        let compose = app.buttons["编排卡片"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "页头没有「编排」入口")
        compose.tap()

        let sizeButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "改变卡片大小")
        ).firstMatch
        XCTAssertTrue(sizeButton.waitForExistence(timeout: 5), "编排态没有尺寸控件")

        let before = sizeButton.label
        sizeButton.tap()

        let changed = NSPredicate(format: "label != %@", before)
        expectation(for: changed, evaluatedWith: sizeButton)
        waitForExpectations(timeout: 3)
    }

    /// 草稿行：点开 → 点建议 → 必须出现一张变更卡。
    func testDraftProducesChangeCard() {
        let app = launch()
        let open = app.buttons["打开草稿"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "底部没有草稿行")
        open.tap()

        let suggestion = app.buttons["自检一次"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "草稿行没有建议项")
        suggestion.tap()

        XCTAssertTrue(app.staticTexts["经本机代理自检"].waitForExistence(timeout: 5),
                      "点了建议却没有生成变更卡")
    }

    /// 时间河：拖一下，顶部读数必须进入「回看中」。
    func testRiverScrubFreezes() {
        let app = launch()
        let river = app.descendants(matching: .any)["lp.river"]
        XCTAssertTrue(river.waitForExistence(timeout: 10), "首屏没有时间河")

        let start = river.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.5))
        let end = river.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: end)

        let frozen = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "回看中")
        ).firstMatch
        XCTAssertTrue(frozen.waitForExistence(timeout: 2), "拖动后没有进入回看态")
    }
}
