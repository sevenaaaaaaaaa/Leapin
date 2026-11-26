import SwiftUI
import LeapinCore
import LeapinRuntime
import LeapinPolicy

/// 「为什么」动词页：连接 / 指标 / 探测 / 诊断 四个 tab。
///
/// M2 的分工（docs/tasks/product-v4.md）：T-06 立壳，T-07 给连接 tab 加搜索注入，
/// T-11 把指标 tab 接到内嵌的 `ObservationView(embedded: true)`，T-12 收探测与诊断，
/// 并在这一页完成 S2 的原地改路：`RuleDraft` 编辑器 → `NetworkAssistantModel.submit(host:policy:)`
/// → 同一页重测。`.capture` 仍是 `.why` 的深链 alias，两个 rawValue 落到这一页。
///
/// 页面自己只剩一条「问路」栏：输入即算，判定（同一条路横过来）就在输入框下面。
/// tab 住在页头里，所以它和下面的筛选 chip 不再是同一种东西。
@MainActor
struct WhyPage: View {
    /// tab 的顺序就是 PRD 里四个问题的顺序；rawValue 用英文，标题才是产品话术。
    enum Tab: String, CaseIterable, Identifiable {
        case connections, metrics, probes, diagnostics

        var id: String { rawValue }

        var title: String {
            switch self {
            case .connections: return "连接"
            case .metrics: return "指标"
            case .probes: return "探测"
            case .diagnostics: return "诊断"
            }
        }

        var icon: String {
            switch self {
            case .connections: return "point.3.connected.trianglepath.dotted"
            case .metrics: return "chart.xyaxis.line"
            case .probes: return "dot.radiowaves.left.and.right"
            case .diagnostics: return "stethoscope"
            }
        }
    }

    /// 打开页面时落在哪个 tab。`.capture` 深链与 `.why` 都从「连接」进。
    let initialTab: Tab

    /// 四个动词共享的上下文。页面出现时向它取一次 host（见 `consumeRouteIfNeeded()`）。
    @EnvironmentObject private var routes: RouteContext

    @State private var tab: Tab

    /// 连接 tab 的初始过滤词。只有真的取到 host 才会变，取不到就一直是空串。
    @State private var seed = ""

    /// 「问路」栏里的字。输入即算，不跳页：trace 由它派生。
    @State private var query = ""
    @FocusState private var queryFocused: Bool

    /// 同一次挂载里是否已经取过：本地守卫，和 `RouteContext.take` 的「每个动词一次」叠着用。
    @State private var consumedRoute = false

    /// 本次挂载里已经出现过（或正在显示）的 tab。
    ///
    /// tab 切换**不销毁**已经出现的 tab：`CaptureView` 的搜索词、选中行、暂停状态都是它自己的
    /// `@State`，销毁重建会把用户输入一起清掉，新实例还会把已经用过的 seed 再写一次
    /// （T-07 第 1 轮评审的 blocking）。没被选过的 tab 不挂载——看不见的 tab 不跟着数据刷新；
    /// 出现过的就一直留着，靠 opacity 显隐。
    @State private var mounted: Set<Tab>

    /// 探测与诊断两个 tab 共用一个工作区模型：同一个主机的一次重测，两个 tab 看的是同一份证据。
    @StateObject private var assistant = NetworkAssistantModel()

    /// 只读内核类型：Mihomo 下规则由原始配置管理，原地写规则会被引擎拒绝，
    /// 入口先禁用并把原因写进 help，别让人填完表单才看到红字（T-14 评审 O8）。
    @ObservedObject private var engine = LeapinEngine.shared

    /// 原地改路编辑器。非 nil 就弹；保存成功后关掉并切到诊断 tab 看结果。
    @State private var ruleEditor: RuleDraftSeed?

    private static let owner = "why"
    private static let tabs: [LPTab] = Tab.allCases.map { LPTab(id: $0.rawValue, title: $0.title) }

    init(initialTab: Tab = .connections) {
        self.initialTab = initialTab
        _tab = State(initialValue: initialTab)
        _mounted = State(initialValue: [initialTab])
        #if DEBUG
        // 快照用：LEAPIN_SNAPSHOT_ASK=github.com 让「问路」栏一出来就带着一个域名，
        // 于是能拍到判定卡。正式构建里不存在这条路，带上 host 进来只走 RouteContext。
        if let asked = ProcessInfo.processInfo.environment["LEAPIN_SNAPSHOT_ASK"], !asked.isEmpty {
            _query = State(initialValue: asked)
        }
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            askBar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { consumeRouteIfNeeded() }
        .lpHeaderTabs(owner: Self.owner, items: Self.tabs, selected: tab.rawValue) { id in
            guard let next = Tab(rawValue: id) else { return }
            select(next)
        }
        .sheet(item: $ruleEditor) { draft in
            RuleDraftEditor(seed: draft, policies: policyChoices) { saved in
                save(draft: saved)
            }
        }
    }

    /// 取一次 host，同时喂给连接 tab 的搜索框和这一页自己的「问路」栏。
    ///
    /// 以前它只喂连接列表：带着 host 从别页过来，看到的是一个空的判定框，
    /// 得再敲一遍才有答案。现在落地就出判定——这才叫带着上下文过来。
    ///
    /// `RouteContext.take` 自带「每个动词只取一次」的语义（T-05 的 WorkbenchTests 已覆盖），
    /// 这里再加一道本地守卫，让同一次挂载里的重复回调不重复取；取不到就什么都不动。
    private func consumeRouteIfNeeded() {
        guard !consumedRoute else { return }
        consumedRoute = true
        guard let subject = routes.take(for: .why), !subject.host.isEmpty else { return }
        seed = subject.host
        if query.isEmpty { query = subject.host }
    }

    /// 选中一个 tab 的同时把它标记为已挂载（挂载要发生在 body 重算之前，
    /// 否则第一次点开的 tab 会先空一帧再出现）。
    private func select(_ new: Tab) {
        mounted.insert(new)
        LPMotion.run(LPMotion.press) { tab = new }
    }

    // MARK: - 问路栏 + 判定

    /// 这一页的输入框问的是这一页自己的问题，所以它比下面的列表过滤大一号。
    private var askBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                LPAskField(text: $query,
                           placeholder: "输入域名或 IP，看它落在哪条规则、哪个出口",
                           icon: "point.3.connected.trianglepath.dotted",
                           focus: $queryFocused) { _ in }
                    .frame(width: 380)
                if hostText.isEmpty {
                    Text("试试")
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textTertiary)
                    // 示例必须是真能解析的站点：随手里填的一个「公司内网」会被 SiteTarget 判成非法输入，
                    // 空态的示例 chip 反手给出一句错误提示，比不放示例更糟。
                    ForEach(Self.examples, id: \.self) { example in
                        LPChip(title: example, selected: false) { query = example }
                    }
                }
                Spacer(minLength: 8)
                Button("改成走公司…") { openRuleEditor() }
                    .buttonStyle(LPGhostButtonStyle())
                    .disabled(assistant.busy || engine.executionKernel != .native)
                    .help(ruleEntryHelp)
            }
            .padding(.top, 12)

            if let answer = answer {
                verdict(answer.match, live: answer.live)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            } else if !hostText.isEmpty {
                Text("这个输入不像域名或 IP。")
                    .font(.system(size: 12))
                    .foregroundStyle(LP.danger)
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, LPSpace.inset)
        .lpAnimation(LPMotion.standard, value: hostText)
    }

    private static let examples = ["github.com", "api.openai.com", "example.com"]

    /// 判定就是这一页的主角：同一条路，出口是 22pt 的朱红字。
    /// 右边留给证据：命中的原始规则和最后一步 trace；没在跑时如实写明这是预估。
    private func verdict(_ match: RuleMatch, live: Bool) -> some View {
        HStack(alignment: .center, spacing: 24) {
            RouteLine(nodes: traceNodes, onInk: false)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 4) {
                if let rule = match.matchedRule {
                    Text(rule.raw)
                        .font(LPFont.mono(11))
                        .foregroundStyle(LP.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: 360, alignment: .trailing)
                } else {
                    Text("没有规则命中，按默认策略走。")
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textSecondary)
                }
                if live {
                    if let trace = match.trace.last {
                        Text(trace)
                            .font(.system(size: 11))
                            .foregroundStyle(LP.textTertiary)
                            .lineLimit(2)
                            .frame(maxWidth: 360, alignment: .trailing)
                    }
                } else {
                    Text("按已保存的规则预估 · 服务未运行，外部规则集未加载")
                        .font(.system(size: 11))
                        .foregroundStyle(LP.textTertiary)
                        .lineLimit(2)
                        .frame(maxWidth: 360, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .lpSheet()
        .accessibilityElement(children: .contain)
    }

    /// 输入里能取出 host 才算数；取不出（空、带空格、不是 http/https 形态）就当没输入。
    private var hostText: String {
        SiteTarget(query)?.host ?? ""
    }

    /// 引擎在跑就问引擎；没在跑就按已保存的规则离线判一次，并说明这是预估。
    ///
    /// 以前没在跑时这一栏对任何合法域名都写「这个输入不像域名或 IP」：引擎的
    /// `explain` 在没有规则引擎时返回 nil，页面把「答不上来」画成了「你输错了」。
    /// 「它为什么打不开」恰恰最常发生在没接管的时候，而规则是存着的，离线判得出来。
    private var answer: (match: RuleMatch, live: Bool)? {
        let host = hostText
        guard !host.isEmpty else { return nil }
        if let match = engine.explain(host: host) { return (match, true) }
        guard engine.state != .running else { return nil }
        let saved = RuleEngine(profile: engine.profile)
        return (saved.explain(ConnectionMeta(host: host, port: 443)), false)
    }

    private var traceNodes: [RouteLine.Node] {
        let match = answer?.match
        let ruleText: String
        var ruleDetail = "落到默认策略"
        if let rule = match?.matchedRule {
            ruleText = "\(rule.kind.rawValue.uppercased()) \(rule.value)"
            if let chain = match?.chain, let index = chain.index {
                ruleDetail = "第 \(index) 条 · 共 \(chain.total) 条"
            } else {
                ruleDetail = "第一条命中的规则"
            }
        } else {
            ruleText = "没有规则命中"
        }
        return [
            .init(hostText, subtitle: "要访问的站点"),
            .init(ruleText, subtitle: ruleDetail, state: .current),
            .init(match?.policy ?? "DIRECT", subtitle: "出口策略", state: .current, prominent: true),
        ]
    }

    // MARK: - 四个 tab 的内容

    /// 四个 tab 都活在一个 ZStack 里，靠 opacity 显隐 —— `switch` 会销毁重建，不能用来切 tab。
    ///
    /// 隐藏的 tab：不吃点击（`allowsHitTesting`）、对读屏隐藏（`accessibilityHidden`），
    /// 并且连接 tab 会收到 `isActive: false`，不抢全窗口的「聚焦搜索框」请求。
    @ViewBuilder private var content: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Tab.allCases) { item in
                if mounted.contains(item) {
                    tabContent(item)
                        .opacity(tab == item ? 1 : 0)
                        .allowsHitTesting(tab == item)
                        .accessibilityHidden(tab != item)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func tabContent(_ item: Tab) -> some View {
        switch item {
        // 连接 tab 带搜索注入：seed 只在这里喂，且 CaptureView 只在这个实例出现一次。
        case .connections: CaptureView(initialSearch: seed, isActive: item == tab)
        // 指标 tab 内嵌观测视图：去掉它的页头，只留实时速率 / 连接数 / 命中统计。
        case .metrics: ObservationView(embedded: true)
        // 探测 = 工作区的检查面（命中链 / DNS trace / 直连与代理耗时）；诊断 = 再加报告与导出。
        case .probes: DiagnosticsWorkspace(assistant: assistant, scope: .probes, embedded: true, isActive: item == tab)
        case .diagnostics: DiagnosticsWorkspace(assistant: assistant, scope: .full, embedded: true, isActive: item == tab)
        }
    }

    // MARK: - 原地改路（S2）

    /// 编辑器能选的出口：当前配置的策略组、规则里已经在用的 policy、以及 DIRECT。
    /// 从现配置里取，不编一份可能与引擎对不上的清单。
    private var policyChoices: [String] {
        let engine = LeapinEngine.shared
        var names = engine.profile.groups.map(\.name)
        names.append(contentsOf: engine.profile.rules.map(\.policy))
        names.append("DIRECT")
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 默认选一个真能走的出口：优先可选策略组，其次第一个组，再退到 PROXY。
    private var defaultPolicy: String {
        let groups = LeapinEngine.shared.profile.groups
        if let selectable = groups.first(where: { $0.type == .select })?.name { return selectable }
        if let first = groups.first?.name { return first }
        return policyChoices.contains("PROXY") ? "PROXY" : "DIRECT"
    }

    /// 打开编辑器时预填当前上下文里的主机：优先「问路」栏里正在看的那个，
    /// 其次才是连接 tab 带过来的 seed——用户正在盯着谁，就替谁改路。
    ///
    /// 只读 seed 与 query，不读 `peek`：subject 被取走之后仍留在 RouteContext 里，页面重新挂载时
    /// 拿它预填会把上一次的 host 当成这一次的（用户没带上下文时应当让编辑器空着）。
    private func openRuleEditor() {
        let host = SiteTarget(query)?.host ?? seed
        ruleEditor = RuleDraftSeed(host: host, policy: defaultPolicy)
    }

    private var ruleEntryHelp: String {
        if engine.executionKernel != .native {
            return "Mihomo 内核的规则由原始配置管理：请在配置里改，这里不写。"
        }
        if assistant.busy {
            return "正在检查中：等这次检查结束再改规则。"
        }
        return "生成一条 host 精确规则，并在这一页用新规则重测"
    }

    /// 保存 = 写一条精确规则 + 用新规则重测，全程留在本页。
    ///
    /// 返回 nil 表示成功；返回一句话表示失败，编辑器会把这句话显示在原处、不关 sheet ——
    /// 失败还把表单关掉，用户刚填的 host 就丢了（T-14 评审 B2）。
    private func save(draft: RuleDraftSeed) -> String? {
        guard assistant.submit(host: draft.host, policy: draft.policy) else {
            return assistant.message ?? "现在无法写入规则，请稍后再试。"
        }
        ruleEditor = nil
        mounted.insert(.diagnostics)
        LPMotion.run(LPMotion.standard) { tab = .diagnostics }
        return nil
    }
}

/// 编辑器带过来的一份待写规则。`Identifiable` 只是为了让 `.sheet(item:)` 能弹出。
struct RuleDraftSeed: Identifiable, Equatable {
    let id = UUID()
    var host: String
    var policy: String
}

/// 原地改路编辑器：host + policy 一条精确规则，保存后立刻在本页重测。
@MainActor
private struct RuleDraftEditor: View {
    @Environment(\.dismiss) private var dismiss
    let seed: RuleDraftSeed
    let policies: [String]
    /// 返回 nil 表示保存成功；返回一句话表示失败，原因显示在表单里、sheet 不关。
    let onSave: (RuleDraftSeed) -> String?

    @State private var host: String
    @State private var policy: String
    @State private var error: String?
    @FocusState private var hostFocused: Bool

    init(seed: RuleDraftSeed, policies: [String], onSave: @escaping (RuleDraftSeed) -> String?) {
        self.seed = seed
        self.policies = policies
        self.onSave = onSave
        _host = State(initialValue: seed.host)
        _policy = State(initialValue: seed.policy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("改成走公司")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LP.text)
            Text("生成一条只含这个 host 的规则，保存后就在「为什么」里用新规则重测同一个主机。")
                .font(.system(size: 13))
                .foregroundStyle(LP.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("主机或完整网址", text: $host)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($hostFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
                        .fill(LP.sheet)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
                        .strokeBorder(hostFocused ? LP.accent : LP.lineStrong,
                                      lineWidth: hostFocused ? 1.5 : 1)
                )
            HStack(spacing: 10) {
                Text("走哪条").font(.system(size: 13)).foregroundStyle(LP.textSecondary)
                Picker("出口", selection: $policy) {
                    ForEach(policies, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .tint(LP.accent)
                Spacer(minLength: 0)
            }
            if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(LP.danger)
            }
            HStack(spacing: 10) {
                Text("写的是 host 精确规则，不动其他规则；保存后可撤销。")
                    .font(.system(size: 11))
                    .foregroundStyle(LP.textTertiary)
                Spacer(minLength: 8)
                Button("取消") { dismiss() }.buttonStyle(LPGhostButtonStyle())
                Button("保存并原地重测") { save() }
                    .buttonStyle(LPPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .foregroundStyle(LP.text)
        .onAppear { hostFocused = true }
    }

    private func save() {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = SiteTarget(trimmed) else {
            error = "这不是可写规则的域名：请输入主机名或完整网址。"
            return
        }
        if let message = onSave(RuleDraftSeed(host: target.host, policy: policy)) {
            error = message
        } else {
            dismiss()
        }
    }
}
