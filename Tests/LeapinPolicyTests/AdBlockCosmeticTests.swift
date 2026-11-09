import XCTest
@testable import LeapinPolicy

/// POL-03/POL-04: cosmetic rules must be indexed by domain key, not scanned
/// linearly per request, and building the index must not be quadratic.
final class AdBlockCosmeticTests: XCTestCase {

    private func rule(_ domain: String, _ selector: String, exception: Bool = false) -> CosmeticRule {
        CosmeticRule(domain: domain, selector: selector, isException: exception)
    }

    func testCosmeticSelectorsFollowSuffixChainAndExceptionsWin() {
        let engine = AdBlockEngine(blockRules: [], allowRules: [], cosmeticRules: [
            rule("example.com", ".ad"),
            rule("example.com", ".ad"),
            rule("sub.example.com", ".sub"),
            rule("*", ".global"),
            rule("example.com", ".ad", exception: true),
        ])

        let deep = Set(engine.cosmeticSelectors(for: "a.sub.example.com"))
        XCTAssertTrue(deep.contains(".sub"))
        XCTAssertTrue(deep.contains(".global"))
        XCTAssertFalse(deep.contains(".ad"), "exception must remove the parent selector")

        let own = Set(engine.cosmeticSelectors(for: "example.com"))
        XCTAssertEqual(own, [".global"])

        XCTAssertEqual(engine.cosmeticSelectors(for: "other.test"), [".global"])
    }

    func testTwentyThousandCosmeticRulesBuildInLinearTime() {
        var rules: [CosmeticRule] = []
        rules.reserveCapacity(20_000)
        for i in 0..<20_000 {
            rules.append(rule("site\(i % 500).example.com", ".ad-\(i)"))
        }
        for i in 0..<200 {
            rules.append(rule("ex\(i % 100).example.com", ".ad-\(i)", exception: true))
        }

        let started = Date()
        let engine = AdBlockEngine(blockRules: [], allowRules: [], cosmeticRules: rules)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 2.0, "20k cosmetic rules took \(elapsed)s to index")
        XCTAssertEqual(engine.ruleCount, rules.count)

        let selectors = engine.cosmeticSelectors(for: "site0.example.com")
        XCTAssertEqual(selectors.count, 40)
        XCTAssertTrue(selectors.contains(".ad-0"))
        XCTAssertEqual(engine.cosmeticSelectors(for: "ex0.example.com"), [])

        // Hot path: 2k lookups over 20k rules should stay well under a second.
        let queryStarted = Date()
        var total = 0
        for i in 0..<2_000 {
            total += engine.cosmeticSelectors(for: "site\(i % 500).example.com").count
        }
        let queryElapsed = Date().timeIntervalSince(queryStarted)
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThan(queryElapsed, 1.0, "2k cosmetic lookups took \(queryElapsed)s")
    }
}
