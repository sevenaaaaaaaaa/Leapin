import Combine
import Foundation
import LeapinCore

// MARK: - The four verbs

/// The workbench layer has one object — a routing decision — and four verbs are its four operations.
///
/// HLD §3 fixes the order, the wording and the landing page of each verb; the sidebar,
/// the ⌘1..⌘4 menu and the command palette all read from this one type so they cannot drift.
public enum WorkbenchVerb: String, CaseIterable, Sendable, Identifiable {
    case goWhere
    case howJudged
    case whatChanged
    case why

    public var id: String { rawValue }

    /// The row title in the sidebar: 走哪 / 怎么判 / 改成什么 / 为什么.
    public var title: String {
        switch self {
        case .goWhere: return "走哪"
        case .howJudged: return "怎么判"
        case .whatChanged: return "改成什么"
        case .why: return "为什么"
        }
    }

    /// The user's own question from PRD §2.2. Shown as the one-line subtitle of the verb page,
    /// so a reword here is a product change, not a copy edit.
    public var question: String {
        switch self {
        case .goWhere: return "让 X 走 Y"
        case .howJudged: return "规则为什么这样定"
        case .whatChanged: return "把请求 / 响应改掉"
        case .why: return "它为什么没走成"
        }
    }

    /// Raw value of `AppModel.Section` this verb opens.
    ///
    /// `why` is a new Section raw value (T-06 adds the case); `capture` stays as a deep-link alias.
    public var sectionRaw: String {
        switch self {
        case .goWhere: return "dashboard"
        case .howJudged: return "rules"
        case .whatChanged: return "rewrite"
        case .why: return "why"
        }
    }

    /// ⌘<shortcut>. Fixed in HLD §3: ⌘1 走哪, ⌘2 怎么判, ⌘3 改成什么, ⌘4 为什么.
    public var shortcut: String {
        switch self {
        case .goWhere: return "1"
        case .howJudged: return "2"
        case .whatChanged: return "3"
        case .why: return "4"
        }
    }

    /// SF Symbol name — the same one `AppModel.Section.icon` draws for the target page
    /// (`why` reuses the capture icon, because Section.why is an alias of the capture page).
    public var icon: String {
        switch self {
        case .goWhere: return "gauge.with.dots.needle.67percent"
        case .howJudged: return "arrow.triangle.branch"
        case .whatChanged: return "arrow.triangle.2.circlepath"
        case .why: return "waveform.path.ecg"
        }
    }
}

// MARK: - Where a sidebar row lands

/// What pressing a sidebar row does: switch to a section, or open the import center.
/// 工具行一律是 section：侧栏长得一样的入口，点了必须做同一件事——换页，
/// 而不是有的换页、有的弹窗（弹窗盖住主窗口，也没法和主窗口并排看）。
public enum WorkbenchDestination: Equatable, Hashable, Sendable {
    case section(String)
    /// Import center (`app.beginImport()`) — not the system file picker.
    case importCenter
}

// MARK: - The 11-row sidebar plan

/// The sidebar as pure data: 3 groups, 11 rows, 4 verbs. The view layer renders this and
/// decides nothing about order, grouping or landing places on its own.
public enum WorkbenchSidebar {

    public struct Row: Identifiable, Sendable {
        public var title: String
        public var icon: String
        /// ⌘<shortcut>; nil for every row that is not one of the four verbs.
        public var shortcut: String?
        public var destination: WorkbenchDestination

        /// Titles are unique across the 11 rows, so the title is the stable id.
        public var id: String { title }

        public init(title: String, icon: String, shortcut: String? = nil, destination: WorkbenchDestination) {
            self.title = title
            self.icon = icon
            self.shortcut = shortcut
            self.destination = destination
        }
    }

    public struct Group: Identifiable, Sendable {
        public var name: String
        public var rows: [Row]

        public var id: String { name }

        public init(name: String, rows: [Row]) {
            self.name = name
            self.rows = rows
        }
    }

    /// 工作 4 + 工具 5 + 收纳 2 = 11. The four verb rows take their title, icon and shortcut
    /// from `WorkbenchVerb`, so the two lists cannot disagree.
    public static let groups: [Group] = [
        Group(name: "工作", rows: [
            Row(title: WorkbenchVerb.goWhere.title, icon: WorkbenchVerb.goWhere.icon,
                shortcut: WorkbenchVerb.goWhere.shortcut,
                destination: .section(WorkbenchVerb.goWhere.sectionRaw)),
            Row(title: WorkbenchVerb.howJudged.title, icon: WorkbenchVerb.howJudged.icon,
                shortcut: WorkbenchVerb.howJudged.shortcut,
                destination: .section(WorkbenchVerb.howJudged.sectionRaw)),
            Row(title: WorkbenchVerb.whatChanged.title, icon: WorkbenchVerb.whatChanged.icon,
                shortcut: WorkbenchVerb.whatChanged.shortcut,
                destination: .section(WorkbenchVerb.whatChanged.sectionRaw)),
            Row(title: WorkbenchVerb.why.title, icon: WorkbenchVerb.why.icon,
                shortcut: WorkbenchVerb.why.shortcut,
                destination: .section(WorkbenchVerb.why.sectionRaw)),
        ]),
        Group(name: "工具", rows: [
            Row(title: "SSH", icon: "terminal", destination: .section("ssh")),
            Row(title: "NAS", icon: "externaldrive.connected.to.line.below", destination: .section("nas")),
            Row(title: "回家", icon: "house", destination: .section("home")),
            Row(title: "公司内网", icon: "building.2", destination: .section("company")),
            Row(title: "分享与调试", icon: "link", destination: .section("tools")),
        ]),
        Group(name: "收纳", rows: [
            Row(title: "导入", icon: "square.and.arrow.down", destination: .importCenter),
            Row(title: "设置", icon: "gearshape", destination: .section("settings")),
        ]),
    ]

    /// The 11 rows in display order, for the "前往" menu and the command palette.
    public static var rows: [Row] { groups.flatMap(\.rows) }
}

// MARK: - The one context the four verbs share

/// What the user pointed at: a host, maybe a port, where the fact came from, and when.
public struct RouteSubject: Equatable, Sendable {

    public enum Source: String, CaseIterable, Sendable {
        /// Picked from a captured connection.
        case capture
        /// From a rule row (how-judged → why).
        case rule
        /// From the overview's current decision.
        case dashboard
        /// Typed by hand.
        case manual
    }

    public var host: String
    public var port: Int?
    public var source: Source
    public var at: Date

    public init(host: String, port: Int? = nil, source: Source = .manual, at: Date = Date()) {
        self.host = host
        self.port = port
        self.source = source
        self.at = at
    }
}

/// The subject carried across the four verb pages.
///
/// Hard rule from PRD §2.2 / HLD §5: every verb may consume the same subject **once**.
/// `take` hands it over and remembers who took it, so switching tabs — in either direction,
/// in any mount order — never replays a stale context, while a verb that has not asked yet
/// still gets it. `peek` is the read-only door for views that only want to display it.
@MainActor
public final class RouteContext: ObservableObject {

    @Published public private(set) var subject: RouteSubject?

    /// Verbs that already consumed the current subject; cleared by `focus` and `clear`.
    private var taken: Set<WorkbenchVerb> = []

    public init() {}

    /// Hand a new subject to the workbench. A new subject is a new context: everyone may take it again.
    public func focus(_ subject: RouteSubject) {
        self.subject = subject
        taken.removeAll()
    }

    /// Read the current subject without consuming it.
    public func peek(for verb: WorkbenchVerb) -> RouteSubject? {
        subject
    }

    /// Consume the current subject for one verb. The first call for a verb returns it; every
    /// later call for that verb returns nil until the subject is replaced.
    public func take(for verb: WorkbenchVerb) -> RouteSubject? {
        guard let subject, !taken.contains(verb) else { return nil }
        taken.insert(verb)
        return subject
    }

    /// Forget both the subject and who consumed it.
    public func clear() {
        subject = nil
        taken.removeAll()
    }
}

// MARK: - Rule draft: "why" hands a host to "how judged"

/// One editable rule, ready to become a real `Rule`.
///
/// The policy always comes from the draft. Writing `DIRECT` here would silently undo the route
/// the user just chose in "why", which is the exact bug this atomic exists to prevent.
public struct RuleDraft: Equatable, Sendable {

    public var host: String
    /// Outbound or policy-group name, exactly as the user picked it.
    public var policy: String
    /// Where the host came from; kept for the "why → how judged" hand-off.
    public var source: RouteSubject.Source

    public init(host: String, policy: String, source: RouteSubject.Source = .manual) {
        self.host = host
        self.policy = policy
        self.source = source
    }

    /// The exact rule line this draft adds — an exact-host `DOMAIN` rule, same shape as the
    /// rules `HomeConnections` and `CompanyAccess` already insert.
    public var rule: Rule {
        Rule(kind: .domain, value: host, policy: policy, raw: "DOMAIN,\(host),\(policy)")
    }

    /// Add the draft's rule on top of `rules`.
    ///
    /// A rule with the same kind, value and policy already present means the answer is already
    /// there: the list comes back untouched, so saving twice cannot stack duplicates.
    public func inserting(into rules: [Rule]) -> [Rule] {
        let alreadyThere = rules.contains {
            $0.kind == .domain && $0.value == host && $0.policy == policy
        }
        guard !alreadyThere else { return rules }
        return [rule] + rules
    }

    /// The same operation under the name T-05's DoD uses (… → `makeRuleSetEntry` → `diagnose`).
    public func makeRuleSetEntry(existing: [Rule]) -> [Rule] {
        inserting(into: existing)
    }
}
