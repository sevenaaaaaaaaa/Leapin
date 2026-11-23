import XCTest
import LeapinCore
@testable import LeapinRuntime

/// T-05: the four verbs, the route context they share, the 11-row sidebar plan,
/// and the rule draft that "why" hands to "how judged".
///
/// The whole file is about pure data and in-memory state: no SwiftUI, no engine.
final class WorkbenchTests: XCTestCase {

    // MARK: - 1. The four verbs (HLD §3)

    func testVerbsAreTheFourVerbsInOrder() {
        XCTAssertEqual(WorkbenchVerb.allCases, [.goWhere, .howJudged, .whatChanged, .why])
        XCTAssertEqual(WorkbenchVerb.allCases.map(\.rawValue), ["goWhere", "howJudged", "whatChanged", "why"])
    }

    func testVerbTitlesAreTheFourQuestionsInPlainWords() {
        XCTAssertEqual(WorkbenchVerb.allCases.map(\.title), ["走哪", "怎么判", "改成什么", "为什么"])
    }

    /// The question text is the user's own wording from PRD §2.2, not a paraphrase:
    /// the sidebar and the command palette both show it, so a reword is a product change.
    func testVerbQuestionsQuoteThePRD() {
        XCTAssertEqual(WorkbenchVerb.allCases.map(\.question),
                       ["让 X 走 Y", "规则为什么这样定", "把请求 / 响应改掉", "它为什么没走成"])
    }

    func testVerbSectionRawKeepsTheDeepLinkNames() {
        XCTAssertEqual(WorkbenchVerb.allCases.map(\.sectionRaw), ["dashboard", "rules", "rewrite", "why"])
    }

    func testVerbShortcutsAreOneToFour() {
        XCTAssertEqual(WorkbenchVerb.allCases.map(\.shortcut), ["1", "2", "3", "4"])
        // ⌘1..⌘4 必须分开：两个动词共用一个快捷键，就等于有一个动词按不到。
        XCTAssertEqual(Set(WorkbenchVerb.allCases.map(\.shortcut)).count, WorkbenchVerb.allCases.count)
    }

    /// The icons reuse the SF Symbols the sidebar already draws for those pages,
    /// so the verb row and the page it opens never disagree.
    func testVerbIconsReuseTheSectionIcons() {
        XCTAssertEqual(WorkbenchVerb.allCases.map(\.icon),
                       ["gauge.with.dots.needle.67percent",
                        "arrow.triangle.branch",
                        "arrow.triangle.2.circlepath",
                        "waveform.path.ecg"])
    }

    // MARK: - 2. The 11-row sidebar plan (HLD §3)

    func testSidebarIsThreeGroupsOfFourFiveTwo() {
        let groups = WorkbenchSidebar.groups
        XCTAssertEqual(groups.map(\.name), ["工作", "工具", "收纳"])
        XCTAssertEqual(groups.map { $0.rows.count }, [4, 5, 2])
        XCTAssertEqual(WorkbenchSidebar.rows.count, 11)
        // 19 个接触面收成 11 行：标题重复就说明有一行被数了两遍。
        XCTAssertEqual(Set(WorkbenchSidebar.rows.map(\.title)).count, 11)
    }

    func testWorkGroupIsTheFourVerbs() {
        let work = WorkbenchSidebar.groups[0].rows
        XCTAssertEqual(work.map(\.title), ["走哪", "怎么判", "改成什么", "为什么"])
        XCTAssertEqual(work.map(\.destination),
                       [.section("dashboard"), .section("rules"), .section("rewrite"), .section("why")])
        XCTAssertEqual(work.map(\.shortcut), ["1", "2", "3", "4"])
        XCTAssertEqual(work.map(\.icon), WorkbenchVerb.allCases.map(\.icon))
    }

    func testToolGroupMixesTwoSectionsAndThreeSheets() {
        let tools = WorkbenchSidebar.groups[1].rows
        XCTAssertEqual(tools.map(\.title), ["SSH", "NAS", "回家", "公司内网", "分享与调试"])
        XCTAssertEqual(tools.map(\.destination),
                       [.section("ssh"), .section("nas"), .sheet(.home), .sheet(.company), .sheet(.networkTools)])
        XCTAssertTrue(tools.allSatisfy { $0.shortcut == nil }, "工具行不占 ⌘1..⌘4")
    }

    func testStorageGroupIsImportCenterAndSettings() {
        let storage = WorkbenchSidebar.groups[2].rows
        XCTAssertEqual(storage.map(\.title), ["导入", "设置"])
        XCTAssertEqual(storage.map(\.destination), [.importCenter, .section("settings")])
        XCTAssertTrue(storage.allSatisfy { $0.shortcut == nil })
    }

    /// Every landing place appears exactly once, and the three kinds together add up to 11.
    func testLandingPlacesAreCompleteAndUnique() {
        let rows = WorkbenchSidebar.rows
        let sections: [String] = rows.compactMap {
            guard case .section(let raw) = $0.destination else { return nil }
            return raw
        }
        let sheets: [SidebarSheet] = rows.compactMap {
            guard case .sheet(let sheet) = $0.destination else { return nil }
            return sheet
        }
        XCTAssertEqual(sections, ["dashboard", "rules", "rewrite", "why", "ssh", "nas", "settings"])
        XCTAssertEqual(sheets, [.home, .company, .networkTools])
        XCTAssertEqual(rows.filter { $0.destination == .importCenter }.count, 1)
        XCTAssertEqual(sections.count + sheets.count + 1, 11)
        XCTAssertEqual(Set(sections).count, sections.count, "没有两行落到同一个 Section")
        XCTAssertEqual(Set(sheets).count, sheets.count, "没有两行落到同一个 sheet")
    }

    func testOnlyTheFourVerbsCarryAShortcut() {
        let withShortcut = WorkbenchSidebar.rows.filter { $0.shortcut != nil }
        XCTAssertEqual(withShortcut.map(\.title), ["走哪", "怎么判", "改成什么", "为什么"])
        XCTAssertTrue(WorkbenchSidebar.rows.allSatisfy { !$0.icon.isEmpty })
    }

    // MARK: - 3. The shared route context (HLD §5)

    func testRouteSubjectDefaultsToManualNow() {
        let before = Date()
        let subject = RouteSubject(host: "example.com")
        XCTAssertEqual(subject.host, "example.com")
        XCTAssertNil(subject.port)
        XCTAssertEqual(subject.source, .manual)
        XCTAssertGreaterThanOrEqual(subject.at, before)
        XCTAssertEqual(RouteSubject.Source.allCases, [.capture, .rule, .dashboard, .manual])
    }

    @MainActor
    func testTakeSucceedsOncePerVerb() {
        let context = RouteContext()
        let subject = RouteSubject(host: "example.com", port: 443, source: .capture)
        context.focus(subject)
        XCTAssertEqual(context.subject, subject)

        // 同一份上下文，两个动词各取一次都成功。
        XCTAssertEqual(context.take(for: .why), subject)
        XCTAssertEqual(context.take(for: .howJudged), subject)
        // 每个动词到此为止：再取就是 nil，否则切 tab 会反复重放旧上下文。
        XCTAssertNil(context.take(for: .why))
        XCTAssertNil(context.take(for: .howJudged))
        XCTAssertEqual(context.take(for: .goWhere), subject)
        XCTAssertNil(context.take(for: .goWhere))
    }

    @MainActor
    func testPeekNeverConsumesTheContext() {
        let context = RouteContext()
        let subject = RouteSubject(host: "peek.example.com", source: .rule)
        context.focus(subject)
        for _ in 0..<3 {
            XCTAssertEqual(context.peek(for: .whatChanged), subject)
        }
        // peek 看三次之后，take 仍然拿得到 —— 只读就是只读。
        XCTAssertEqual(context.take(for: .whatChanged), subject)
        XCTAssertNil(context.take(for: .whatChanged))
    }

    @MainActor
    func testTakeWithoutASubjectIsNil() {
        let context = RouteContext()
        XCTAssertNil(context.subject)
        for verb in WorkbenchVerb.allCases {
            XCTAssertNil(context.peek(for: verb))
            XCTAssertNil(context.take(for: verb))
        }
    }

    @MainActor
    func testFocusResetsWhatWasAlreadyTaken() {
        let context = RouteContext()
        let first = RouteSubject(host: "first.example.com", source: .capture)
        context.focus(first)
        XCTAssertEqual(context.take(for: .why), first)
        XCTAssertNil(context.take(for: .why))

        let second = RouteSubject(host: "second.example.com", port: 8443, source: .dashboard)
        context.focus(second)
        XCTAssertEqual(context.subject, second)
        // 新 subject = 新上下文：同一个动词可以再取一次。
        XCTAssertEqual(context.take(for: .why), second)
        XCTAssertNil(context.take(for: .why))
    }

    @MainActor
    func testClearDropsSubjectAndTaken() {
        let context = RouteContext()
        context.focus(RouteSubject(host: "gone.example.com"))
        XCTAssertEqual(context.take(for: .why)?.host, "gone.example.com")
        context.clear()
        XCTAssertNil(context.subject)
        for verb in WorkbenchVerb.allCases {
            XCTAssertNil(context.peek(for: verb))
            XCTAssertNil(context.take(for: verb))
        }
        // clear 之后再 focus，take 从零开始。
        let next = RouteSubject(host: "next.example.com")
        context.focus(next)
        XCTAssertEqual(context.take(for: .why), next)
    }

    // MARK: - 4. The rule draft (HLD §5, S2)

    func testDraftInsertsOnTopAndKeepsTheDraftPolicy() {
        let existing = [Rule(kind: .domain, value: "existing.example.com", policy: "Proxy",
                             raw: "DOMAIN,existing.example.com,Proxy")]
        let draft = RuleDraft(host: "company.example.com", policy: "公司内网", source: .capture)
        let next = draft.inserting(into: existing)

        XCTAssertEqual(next.count, 2)
        XCTAssertEqual(next.first?.kind, .domain)
        XCTAssertEqual(next.first?.value, "company.example.com")
        // policy 来自 draft：写死 DIRECT 就等于用户在「为什么」里改的路没生效。
        XCTAssertEqual(next.first?.policy, "公司内网")
        XCTAssertEqual(next.dropFirst().map(\.value), ["existing.example.com"])
    }

    func testDraftIsIdempotentForTheSameKindValueAndPolicy() {
        let draft = RuleDraft(host: "company.example.com", policy: "Proxy", source: .manual)
        let once = draft.inserting(into: [])
        XCTAssertEqual(once.count, 1)
        // 已经存在同一条规则时原样返回，不置顶、不重复。
        XCTAssertEqual(draft.inserting(into: once), once)
        // 连按两次保存也只多一条：重复保存不能叠出两条一样的规则。
        let twice = draft.inserting(into: once)
        XCTAssertEqual(draft.inserting(into: twice), once)
    }

    /// T-05 DoD 2 names the same operation `makeRuleSetEntry(existing:)`; the two must not diverge.
    func testMakeRuleSetEntryIsTheSameOperationAsInserting() {
        let existing = [Rule(kind: .domain, value: "old.example.com", policy: "DIRECT")]
        let draft = RuleDraft(host: "new.example.com", policy: "公司内网", source: .capture)
        XCTAssertEqual(draft.makeRuleSetEntry(existing: existing), draft.inserting(into: existing))
        XCTAssertEqual(draft.makeRuleSetEntry(existing: existing).count, 2)
        XCTAssertEqual(draft.makeRuleSetEntry(existing: existing).first?.policy, "公司内网")
    }

    func testDraftTreatsADifferentPolicyAsAnotherRule() {
        let existing = [Rule(kind: .domain, value: "company.example.com", policy: "Proxy")]
        let draft = RuleDraft(host: "company.example.com", policy: "DIRECT", source: .rule)
        let next = draft.inserting(into: existing)
        XCTAssertEqual(next.count, 2)
        XCTAssertEqual(next.first?.policy, "DIRECT")
    }

    func testDraftDoesNotMistakeAnotherKindForADuplicate() {
        let existing = [Rule(kind: .domainSuffix, value: "example.com", policy: "Proxy")]
        let draft = RuleDraft(host: "example.com", policy: "Proxy", source: .dashboard)
        XCTAssertEqual(draft.inserting(into: existing).count, 2)
    }

    func testDraftKeepsEmptyPolicyAsGivenInsteadOfFallingBackToDirect() {
        let draft = RuleDraft(host: "blank.example.com", policy: "", source: .manual)
        XCTAssertEqual(draft.inserting(into: []).first?.policy, "")
    }
}
