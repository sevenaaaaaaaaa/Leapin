import XCTest
@testable import LeapinRuntime

/// T-02：状态栏图标的字形映射。
///
/// macOS 状态栏按模板渲染，颜色会被系统抹掉，所以四个 tone 只能靠**字形**区分；
/// 颜色只留在面板圆点上。这些用例把映射钉死，防止以后有人顺手把
/// degraded 改回和 normal 一样的盾。
final class ResidentIconTests: XCTestCase {

    // MARK: - 字形

    /// 没在跑：斜线盾。关着和跑着必须长得不一样。
    func testIdleUsesSlashShield() {
        XCTAssertEqual(ResidentTone.idle.iconName, "shield.slash")
    }

    /// 正常：空盾。
    func testNormalUsesPlainShield() {
        XCTAssertEqual(ResidentTone.normal.iconName, "shield.lefthalf.filled")
    }

    /// 降级：盾里一个感叹号——还在跑，但有一件事不对。
    func testDegradedUsesExclamationShield() {
        XCTAssertEqual(ResidentTone.degraded.iconName, "exclamationmark.shield.fill")
    }

    /// 异常：盾里一个叉——引擎自己失败了。
    func testFailedUsesCrossShield() {
        XCTAssertEqual(ResidentTone.failed.iconName, "xmark.shield.fill")
    }

    // MARK: - 无障碍文案

    /// 字形对看不见的人没有意义，所以每个 tone 都要有一句自己的话，
    /// 而且四句互不相同——否则 VoiceOver 读起来又是同一个图标。
    func testAccessibilityTextIsNonEmptyAndDistinctPerTone() {
        let texts = ResidentTone.allCases.map(\.accessibilityText)
        XCTAssertEqual(texts.count, 4, "四个 tone 都应该有文案")
        for (tone, text) in zip(ResidentTone.allCases, texts) {
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(tone.rawValue) 的 accessibilityText 不能为空")
        }
        XCTAssertEqual(Set(texts).count, texts.count, "四句文案必须互不相同：\(texts)")
    }

    /// 四态四个字形：任何两个 tone 撞了同一个字形，状态栏就又说不清话了。
    func testFourTonesUseFourDistinctGlyphs() {
        let icons = ResidentTone.allCases.map(\.iconName)
        XCTAssertEqual(Set(icons).count, icons.count, "四个 tone 的字形必须互不相同：\(icons)")
    }
}
