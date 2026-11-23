import SwiftUI
import LeapinCore
import LeapinRuntime
import LeapinPolicy
import LeapinNet
import LeapinIntegrations

@MainActor
struct RulesView: View {
    @EnvironmentObject private var app: AppModel
    /// 四动词共享上下文（T-05）：规则行把 host 交给「为什么」页时就靠它。
    @EnvironmentObject private var routes: RouteContext
    @ObservedObject private var engine = LeapinEngine.shared
    /// Mihomo 执行时策略组来自内核本身；原生执行时这一段不参与。
    @ObservedObject private var managed = LeapinEngine.shared.managedKernel
    @State private var search = ""
    @State private var showAdd = false
    @State private var selection: String?
    @State private var pendingDelete: Rule?
    @State private var filter: PolicyFilter = .all
    /// Dead rules keyed by their position in the profile (positions survive filtering).
    @State private var diagnostics: [Int: RuleDiagnostic] = [:]
    /// Bumped by the probe refresh timer so measured latency re-renders even though
    /// LPHealth itself is not observable.
    @State private var healthTick = 0
    /// Mihomo 当前的分组与选中项（内核返回）；原生执行时恒为空。
    @State private var managedGroups: [ManagedPolicy] = []
    @State private var groupBusy = false
    @State private var groupNote: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private enum PolicyFilter: String, CaseIterable, Identifiable {
        case all, direct, proxy, reject
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .direct: return "直连"
            case .proxy: return "代理"
            case .reject: return "拦截"
            }
        }
        func matches(_ rule: Rule) -> Bool {
            switch self {
            case .all: return true
            case .direct: return rule.policy.uppercased() == "DIRECT"
            case .reject: return rule.policy.uppercased() == "REJECT"
            case .proxy: return !["DIRECT", "REJECT"].contains(rule.policy.uppercased())
            }
        }
    }

    /// Keeps the profile position for every visible rule so diagnostics and row
    /// numbers stay stable while the list is filtered or searched.
    private var filtered: [(index: Int, rule: Rule)] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return engine.profile.rules.enumerated().compactMap { offset, rule in
            guard filter.matches(rule) else { return nil }
            guard !q.isEmpty else { return (offset, rule) }
            let hit = rule.raw.lowercased().contains(q)
                || rule.value.lowercased().contains(q)
                || rule.policy.lowercased().contains(q)
            return hit ? (offset, rule) : nil
        }
    }

    private func count(for filter: PolicyFilter) -> Int {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return engine.profile.rules.filter { rule in
            guard filter.matches(rule) else { return false }
            guard !q.isEmpty else { return true }
            return rule.raw.lowercased().contains(q)
                || rule.value.lowercased().contains(q)
                || rule.policy.lowercased().contains(q)
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            if engine.executionKernel == .mihomo {
                Text("Mihomo 正在执行原始分流配置。此处为来源预览；修改请到线路与订阅重新导入。")
                    .font(.system(size: 13)).foregroundStyle(LP.textSecondary).padding(12)
            }
            if !engine.temporaryRules.isEmpty {
                temporaryRuleBanner
            }
            toolbar.disabled(engine.executionKernel == .mihomo)
            HStack(alignment: .top, spacing: 22) {
                // 只锁「写」：Mihomo 下规则是来源预览，但读动作（选中、追问为什么、
                // 复制、策略组切换）一律照常——追问只是看，不该跟着写入口一起被冻。
                // 写入口逐个上锁：工具栏、行尾删除、⌫、临时规则清除、空态「添加规则」。
                ruleList
                    .clipShape(RoundedRectangle(cornerRadius: LPGlass.panelRadius, style: .continuous))
                    .lpSheet()
                sidePanel.frame(width: 292)
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)
            .padding(.bottom, 10)
            learnFooter
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
        }
        .navigationTitle("分流规则")
        .sheet(isPresented: $showAdd) {
            AddRuleSheet { rule in
                engine.addRules([rule])
                refreshDiagnostics()
                showAdd = false
                app.showToast("已添加规则 \(rule.value)")
            } onCancel: { showAdd = false }
        }
        .lpConfirm("删除这条规则？",
                   message: pendingDelete.map { "\($0.kind.rawValue.uppercased()),\($0.value),\($0.policy)\n删除后立即生效，可通过重新导入配置恢复。" } ?? "",
                   isPresented: Binding(
                       get: { pendingDelete != nil },
                       set: { if !$0 { pendingDelete = nil } }
                   ),
                   confirmTitle: "删除") {
            guard let rule = pendingDelete else { return }
            engine.removeRule(id: rule.id)
            if selection == rule.id { selection = nil }
            refreshDiagnostics()
            pendingDelete = nil
            app.showToast("已删除 \(rule.value)", kind: .info)
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            // Probe results land in LPHealth, not in an observable object.
            healthTick &+= 1
        }
        .onChange(of: app.searchFocusRequest) { _, _ in
            searchFocused = true
        }
        .onChange(of: search) { _, _ in
            if let selected = selection, !filtered.contains(where: { $0.rule.id == selected }) {
                selection = nil
            }
        }
        .task {
            refreshDiagnostics()
            await refreshPolicyGroups()
        }
        // 判据跟着规则内容走，不只跟条数：改一条规则的 value（条数不变）后，
        // 「永不命中 / 被遮蔽」不能停在旧结论上（T-10 评审 optional）。
        .onChange(of: engine.profile.rules) { _, _ in refreshDiagnostics() }
        .onChange(of: engine.executionKernel) { _, _ in
            Task { await refreshPolicyGroups() }
        }
        .onChange(of: managed.running) { _, _ in
            Task { await refreshPolicyGroups() }
        }
    }

    /// 内核可能给 `load-balance` / `LoadBalance` 两种写法；负载均衡组的下拉必须一起禁用，
    /// 否则选中会抛错（T-10 评审 optional）。
    private static func isLoadBalance(_ type: String) -> Bool {
        type.lowercased().replacingOccurrences(of: "-", with: "") == "loadbalance"
    }

    /// Recomputes dead-rule diagnostics. Only called when the rule set changes
    /// (open / add / delete / reload) — never from `body`, which must stay cheap.
    private func refreshDiagnostics() {
        diagnostics = Self.indexed(engine.ruleDiagnostics())
    }

    private static func indexed(_ list: [RuleDiagnostic]) -> [Int: RuleDiagnostic] {
        var out: [Int: RuleDiagnostic] = [:]
        out.reserveCapacity(list.count)
        for item in list { out[item.index] = item }
        return out
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            LPSearchField(text: $search, placeholder: "搜索域名 / 策略 / 原始规则", width: 235, focus: $searchFocused)

            HStack(spacing: 5) {
                ForEach(PolicyFilter.allCases) { option in
                    LPChip(title: option.title, count: count(for: option), selected: filter == option) {
                        LPMotion.run(LPMotion.press) { filter = option }
                    }
                }
            }

            Text("\(filtered.count) / \(engine.profile.rules.count)")
                .font(LPFont.num(10.5, weight: .medium))
                .foregroundStyle(LP.textTertiary)
            Spacer()
            Button {
                Task {
                    await engine.reloadProfile()
                    refreshDiagnostics()
                }
                app.showToast("配置已重新载入", kind: .info)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold))
                    Text("重载").font(.system(size: 13, weight: .medium))
                }
            }
            .buttonStyle(LPGhostButtonStyle())

            Button {
                showAdd = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("添加规则").font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(LPPrimaryButtonStyle())
        }
        .padding(.horizontal, 32).padding(.vertical, 13)
    }

    /// Temporary rules only live for this run; say so, and make them easy to drop.
    private var temporaryRuleBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 11))
                .foregroundStyle(LP.amber)
            Text("\(engine.temporaryRules.count) 条临时规则（重启后失效，不会写入配置）")
                .font(.system(size: 11))
                .foregroundStyle(LP.textSecondary)
            Text(engine.temporaryRules.map { "\($0.value) → \($0.policy)" }.joined(separator: " · "))
                .font(LPFont.mono(11))
                .foregroundStyle(LP.textTertiary)
                .lineLimit(1)
            Spacer()
            Button("全部清除") {
                engine.clearTemporaryRules()
                app.showToast("已清除临时规则")
            }
            .buttonStyle(LPGhostButtonStyle())
            .disabled(engine.executionKernel == .mihomo)
        }
        .padding(.horizontal, 32)
        .padding(.top, 10)
    }

    private var ruleList: some View {
        Group {
            if filtered.isEmpty {
                LPEmptyState(
                    icon: "list.bullet.rectangle",
                    title: engine.profile.rules.isEmpty ? "还没有规则" : "没有匹配的规则",
                    message: engine.profile.rules.isEmpty
                        ? "可以从配置页导入 Clash / Surge 配置，或手动添加第一条规则。"
                        : "换一个关键词，或把策略筛选切回“全部”。",
                    actionTitle: engine.profile.rules.isEmpty
                        ? (engine.executionKernel == .mihomo ? "只读预览" : "添加规则")
                        : "清除筛选",
                    action: {
                        if engine.profile.rules.isEmpty {
                            // 规则编辑在 Mihomo 下不可用：不开编辑器，免得白填一遍才被拒。
                            guard engine.executionKernel != .mihomo else { return }
                            showAdd = true
                        } else {
                            search = ""; filter = .all
                        }
                    })
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("#").frame(width: 30, alignment: .leading)
                        Text("类型").frame(width: 66, alignment: .leading)
                        Text("匹配值")
                        Spacer(minLength: 8)
                        // 「策略」与行尾按钮之间的 12pt 是 LPRow 的内边距，
                        // 表头照抄同一个数字，两列才对得上。
                        HStack(spacing: 0) {
                            Text("策略").padding(.trailing, 12)
                            Text("为什么")
                                .frame(width: Self.whyColumnWidth, alignment: .trailing)
                        }
                    }
                    .font(LPFont.mono(10, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(LP.textTertiary)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 7)
                    Rectangle().fill(LP.stroke).frame(height: 1)
                    ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filtered, id: \.index) { item in
                            let rule = item.rule
                            // 能取出域名才给「为什么」；取不出来就禁用并在 help 里说明原因，
                            // 不拿一个猜出来的 host 去问为什么。
                            let why = whyHost(for: rule)
                            HStack(spacing: 0) {
                                LPRow(selected: selection == rule.id,
                                      accessibilityText: "\(rule.kind.rawValue) \(rule.value) \(rule.policy)") {
                                    selection = rule.id
                                    listFocused = true
                                } content: {
                                    RuleRow(index: item.index + 1, rule: rule,
                                            diagnostic: diagnostics[item.index])
                                }
                                whyButton(for: rule, host: why)
                            }
                            .overlay(alignment: .bottom) {
                                if item.index != filtered.last?.index {
                                    Rectangle().fill(LP.stroke).frame(height: 1)
                                }
                            }
                            .contextMenu {
                                Button("看它为什么没命中") {
                                    if let why { askWhy(why) }
                                }
                                .disabled(why == nil)
                                Divider()
                                Button("复制匹配值") {
                                    LPClipboard.copy(rule.value)
                                    app.showToast("已复制 \(rule.value)", kind: .info)
                                }
                                Button("复制原始规则") {
                                    LPClipboard.copy(rule.raw)
                                    app.showToast("已复制原始规则", kind: .info)
                                }
                                Divider()
                                // 写入口单独上锁；同一菜单里的「看它为什么没命中」「复制」照旧可用。
                                Button("删除规则", role: .destructive) { pendingDelete = rule }
                                    .disabled(engine.executionKernel == .mihomo)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                    }
                    .focusable()
                    .focused($listFocused)
                    .onMoveCommand { direction in moveSelection(direction) }
                    .onDeleteCommand {
                        // 只锁写：Mihomo 下规则是来源预览，⌫ 不该弹出删除确认。
                        guard engine.executionKernel != .mihomo else { return }
                        if let id = selection, let rule = engine.profile.rules.first(where: { $0.id == id }) {
                            pendingDelete = rule
                        }
                    }

                    tableFooter
                }
            }
        }
    }

    /// 账页的合计行：把「还剩多少、都判给谁」写在表尾，空面板就不再是无解释的白。
    private var tableFooter: some View {
        let direct = filtered.filter { $0.rule.policy.uppercased() == "DIRECT" }.count
        return HStack(spacing: 10) {
            Text("共 \(filtered.count) 条")
            if direct > 0 { Text("·").foregroundStyle(LP.strokeStrong) }
            if direct > 0 { Text("DIRECT \(direct)") }
            if filtered.count - direct > 0 {
                Text("·").foregroundStyle(LP.strokeStrong)
                Text("代理 \(filtered.count - direct)")
            }
            Spacer(minLength: 8)
            Text("首次命中裁决").foregroundStyle(LP.textTertiary)
        }
        .font(LPFont.mono(11))
        .foregroundStyle(LP.textSecondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .overlay(alignment: .top) { LPDivider() }
    }

    // MARK: - 规则行 → 为什么（带 host）

    /// 行尾「为什么」列的宽度；表头和行都用这一个数字，不会各写一遍。
    private static let whyColumnWidth: CGFloat = 34

    /// 从规则的匹配值里取出能查的域名。
    ///
    /// 只有天生就是主机名的写法才取得出来：DOMAIN / DOMAIN-SUFFIX 直接取；
    /// DOMAIN-KEYWORD 只有值本身像域名时才取（`ads` 这种子串不是 host）。
    /// 其余类型一律 nil——按钮因此禁用，原因由 `whyUnavailableReason` 说清。
    private func whyHost(for rule: Rule) -> String? {
        switch rule.kind {
        case .domain, .domainSuffix:
            return Self.hostValue(rule.value)
        case .domainKeyword:
            guard let host = Self.hostValue(rule.value), host.contains(".") else { return nil }
            return host
        default:
            return nil
        }
    }

    /// 把一条规则值规范化成 host；不是主机名就 nil。
    private static func hostValue(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("*.") { value.removeFirst(2) }
        if value.hasPrefix(".") { value.removeFirst() }
        guard !value.isEmpty, value.count <= 253 else { return nil }
        let pattern = #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return value
    }

    /// 为什么这一行不能带 host 去「为什么」页：写清楚，而不是给个灰按钮不说话。
    private func whyUnavailableReason(for rule: Rule) -> String {
        switch rule.kind {
        case .domain, .domainSuffix:
            return "匹配值「\(rule.value)」不是可直接查询的域名（含通配或非法字符）"
        case .domainKeyword:
            return "关键词「\(rule.value)」不是域名，取不出可查询的 host"
        case .domainRegex:
            return "正则规则无法反解出 host"
        case .ipCIDR, .ipCIDR6:
            return "IP 规则没有域名可查；到「为什么」页按连接查看"
        case .srcIPCIDR:
            return "源地址规则没有目标域名可查"
        case .processName:
            return "进程规则没有域名可查"
        case .geoIP:
            return "地区规则没有域名可查"
        case .ruleSet:
            return "规则集没有单一 host；展开规则集后按成员规则查"
        case .and, .or, .not:
            return "组合表达式没有单一 host"
        case .match:
            return "MATCH 是兜底规则，没有具体 host"
        }
    }

    /// 行尾的追问按钮：能取到域名才可点，取不到就禁用并把原因写进 help 与旁白。
    @ViewBuilder
    private func whyButton(for rule: Rule, host: String?) -> some View {
        Button {
            if let host { askWhy(host) }
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(host == nil ? LP.textTertiary.opacity(0.4) : LP.textTertiary)
                .frame(width: Self.whyColumnWidth, height: 22, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(host == nil)
        .help(host.map { "看 \($0) 为什么没命中：带这个 host 去「为什么」页" }
              ?? whyUnavailableReason(for: rule))
        .accessibilityLabel("看它为什么没命中")
        .accessibilityHint(host == nil ? whyUnavailableReason(for: rule) : "带 \(host ?? "") 去为什么页")
    }

    /// HLD §5 的跨页链路：先给上下文，再切页；两页共用同一个 subject。
    private func askWhy(_ host: String) {
        routes.focus(RouteSubject(host: host, source: .rule))
        app.go(to: .why)
    }

    /// 页脚：规则页判的是现状，「学习建议」是下一步——入口放底部，不抢规则表。
    private var learnFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 11))
                .foregroundStyle(LP.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("学习建议")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LP.text)
                Text("不确定怎么分？从 App 列表或截图生成建议，再回这里逐条确认。")
                    .font(.system(size: 11))
                    .foregroundStyle(LP.textTertiary)
            }
            Spacer(minLength: 12)
            Button("打开智能学习") { app.go(to: .learn) }
                .buttonStyle(LPGhostButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .lpPanel(padding: 0)
    }

    // MARK: - 策略组（原生 / Mihomo 两套来源）

    /// 原生执行读 `profile.groups`（selectOutbound 写回配置）；
    /// Mihomo 执行读内核当前分组（selectManagedPolicy 走内核 API）。
    /// 规则在 Mihomo 下不可改，但「哪个组选了哪条线」仍要能切。
    @ViewBuilder
    private var policyGroupsSection: some View {
        if engine.executionKernel == .mihomo {
            managedGroupsSection
        } else {
            nativeGroupsSection
        }
    }

    @ViewBuilder
    private var nativeGroupsSection: some View {
        if engine.profile.groups.isEmpty {
            railNote("当前配置没有策略组")
        } else {
            ForEach(engine.profile.groups) { group in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(group.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(LP.text)
                        Spacer()
                        Text(group.type.rawValue.uppercased())
                            .font(LPFont.mono(11))
                            .tracking(0.6)
                            .foregroundStyle(LP.textTertiary)
                    }
                    LPSelectField(value: Binding(
                        get: { group.selected ?? group.proxies.first ?? "DIRECT" },
                        set: { engine.selectOutbound(group: group.name, outbound: $0) }
                    ), options: group.proxies.map { ($0, $0) })
                    if group.type == .urlTest || group.type == .fallback || group.type == .loadBalance {
                        HStack(spacing: 6) {
                            Text("当前")
                                .font(LPFont.mono(11))
                                .foregroundStyle(LP.textTertiary)
                            Text(engine.state == .running
                                 ? (engine.effectiveMember(group: group.name) ?? "—")
                                 : "未运行")
                                .font(LPFont.mono(11))
                                .foregroundStyle(LP.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            groupHealthNote(group)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var managedGroupsSection: some View {
        if !managed.running {
            railNote(groupNote ?? "Mihomo 内核未运行，启动后这里列出内核的分组与选中项。")
        } else if managedGroups.isEmpty {
            railNote(groupNote ?? "内核还没有返回策略组。")
        } else {
            ForEach(managedGroups) { group in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(group.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(LP.text)
                        Spacer()
                        Text(group.type.uppercased())
                            .font(LPFont.mono(11))
                            .tracking(0.6)
                            .foregroundStyle(LP.textTertiary)
                    }
                    LPSelectField(value: Binding(
                        get: { group.selected },
                        set: { selectManaged(group: group.name, member: $0) }
                    ), options: group.members.map { ($0, $0) })
                        .disabled(groupBusy || Self.isLoadBalance(group.type))
                    if groupBusy {
                        Text("切换中…")
                            .font(LPFont.mono(11))
                            .foregroundStyle(LP.textTertiary)
                    }
                }
                .padding(.vertical, 4)
            }
            railNote("选择交给内核执行，只影响新连接。")
            if let groupNote { railNote(groupNote) }
        }
    }

    /// 拉一次内核当前分组；Mihomo 没在跑就清空，不假装有数据。
    private func refreshPolicyGroups() async {
        guard engine.executionKernel == .mihomo, managed.running else {
            managedGroups = []
            return
        }
        do {
            managedGroups = try await engine.managedPolicies()
            groupNote = nil
        } catch {
            managedGroups = []
            groupNote = Redactor.redact(error.localizedDescription)
        }
    }

    private func selectManaged(group: String, member: String) {
        guard !groupBusy else { return }
        groupBusy = true
        Task {
            do {
                try await engine.selectManagedPolicy(group: group, member: member)
                groupNote = nil
                app.showToast("已切换 \(group) → \(member)，仅新连接生效", kind: .info)
            } catch {
                groupNote = Redactor.redact(error.localizedDescription)
            }
            await refreshPolicyGroups()
            groupBusy = false
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !filtered.isEmpty else { return }
        let current = filtered.firstIndex(where: { $0.rule.id == selection })
        let next: Int
        switch direction {
        case .up:
            next = max(0, (current ?? 0) - 1)
        case .down:
            next = min(filtered.count - 1, (current ?? -1) + 1)
        default:
            return
        }
        selection = filtered[next].rule.id
    }

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                railSection("策略组 / GROUPS") {
                    policyGroupsSection
                }

                railRule

                railSection("出站 / OUTBOUNDS") {
                    ForEach(engine.profile.outbounds) { outbound in
                        HStack(spacing: 8) {
                            Circle().fill(color(for: outbound.type)).frame(width: 5, height: 5)
                            Text(outbound.name)
                                .font(.system(size: 13))
                                .foregroundStyle(LP.text)
                            Spacer()
                            if let ms = engine.latency(for: outbound.name) {
                                Text("\(ms) ms")
                                    .font(LPFont.num(11))
                                    .foregroundStyle(LP.textTertiary)
                            }
                            Text(outbound.type.rawValue)
                                .font(LPFont.mono(11))
                                .foregroundStyle(LP.textTertiary)
                        }
                        .padding(.vertical, 3)
                    }
                }

                railRule

                railSection("规则集 / RULE-SETS") {
                    let sets = engine.profile.rules.filter { $0.kind == .ruleSet }
                    if sets.isEmpty {
                        railNote("未引用规则集")
                    } else {
                        ForEach(sets) { rule in
                            Text(rule.value)
                                .font(LPFont.mono(11))
                                .foregroundStyle(LP.textSecondary)
                                .lineLimit(1)
                        }
                        railNote("规则集在启动时下载/读取并缓存，失败会降级为空。")
                    }
                }

                railRule

                railSection("诊断 / DIAGNOSTICS") {
                    diagnosticsSection
                }

                railRule

                railSection("快捷键 / KEYS") {
                    VStack(alignment: .leading, spacing: 7) {
                        shortcut("⌘F", "聚焦搜索")
                        shortcut("↑ ↓", "选择规则")
                        shortcut("⌫", "删除选中规则")
                        shortcut("⌘K", "命令面板")
                    }
                }
            }
            .padding(.top, 18)
            .padding(.trailing, 4)
        }
        .scrollIndicators(.never)
    }

    /// Fastest measured member of a group, or an honest "not probed yet".
    @ViewBuilder
    private func groupHealthNote(_ group: PolicyGroup) -> some View {
        let scored = group.proxies.compactMap { name in engine.latency(for: name).map { (name, $0) } }
        if let fastest = scored.min(by: { $0.1 < $1.1 }) {
            Text("最快 \(fastest.0) \(fastest.1) ms")
                .font(LPFont.mono(11))
                .foregroundStyle(LP.textTertiary)
                .lineLimit(1)
        } else {
            Text("尚未测速")
                .font(LPFont.mono(11))
                .foregroundStyle(LP.textTertiary)
        }
    }

    /// 死规则总览：先给结论（多少条），再给可点击的例子，点一下跳到该行。
    /// 「死」不止一种：被遮蔽 / 不可达 / 重复 / 规则集缺失 / 永不命中，逐条标出是哪一种。
    @ViewBuilder
    private var diagnosticsSection: some View {
        let dead = deadRules
        if dead.isEmpty {
            railNote("当前 \(engine.profile.rules.count) 条规则都可命中")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(dead.count) 条不会命中")
                    .font(LPFont.mono(10, weight: .semibold))
                    .foregroundStyle(LP.danger)
                ForEach(dead.prefix(4), id: \.diagnostic.index) { item in
                    Button { jump(to: item.diagnostic.index) } label: {
                        HStack(spacing: 6) {
                            Text("#\(item.diagnostic.index + 1)")
                                .font(LPFont.mono(11))
                                .foregroundStyle(LP.textTertiary)
                            Text(item.rule.value)
                                .font(LPFont.mono(11))
                                .foregroundStyle(LP.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(diagnosticLabel(item.diagnostic.kind))
                                .font(LPFont.mono(11))
                                .foregroundStyle(LP.danger)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.diagnostic.reason)
                }
                if dead.count > 4 {
                    railNote("其余 \(dead.count - 4) 条在列表行尾以「被遮蔽 / 不可达」等标记标出。")
                }
            }
        }
    }

    private var deadRules: [(rule: Rule, diagnostic: RuleDiagnostic)] {
        diagnostics.sorted { $0.key < $1.key }.compactMap { index, diagnostic in
            guard engine.profile.rules.indices.contains(index) else { return nil }
            return (engine.profile.rules[index], diagnostic)
        }
    }

    private func jump(to index: Int) {
        guard engine.profile.rules.indices.contains(index) else { return }
        let rule = engine.profile.rules[index]
        search = ""
        filter = .all
        selection = rule.id
        listFocused = true
    }

    /// 标签只在 `RuleRow` 里定义一次，侧栏与行尾不会标出两种叫法。
    private func diagnosticLabel(_ kind: RuleDiagnostic.Kind) -> String {
        RuleRow.diagnosticLabel(kind)
    }

    private func railSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            LPEyebrow(text: title)
            content()
        }
    }

    private var railRule: some View {
        Rectangle().fill(LP.stroke.opacity(0.8)).frame(height: 1)
    }

    private func railNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(LP.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func shortcut(_ key: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            LPKeyCap(keys: key)
            Text(label).font(.system(size: 11)).foregroundStyle(LP.textTertiary)
        }
    }

    private func color(for type: OutboundType) -> Color {
        switch type {
        case .direct: return LP.text.opacity(0.35)
        case .reject: return LP.danger
        default: return LP.text.opacity(0.65)
        }
    }
}

struct RuleRow: View {
    var index: Int
    var rule: Rule
    /// Non-nil when the editor knows this rule can never win — a dead rule must
    /// not look as healthy as a live one.
    var diagnostic: RuleDiagnostic? = nil
    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)")
                .font(LPFont.mono(11))
                .foregroundStyle(LP.textTertiary)
                .frame(width: 30, alignment: .leading)
            Text(label)
                .font(LPFont.mono(10, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(LP.textTertiary)
                .lineLimit(1)
                .frame(width: 66, alignment: .leading)
            Text(rule.value)
                .font(LPFont.mono(13))
                .foregroundStyle(LP.text)
                .lineLimit(1)
            if rule.noResolve { Badge(text: "no-resolve", color: LP.textTertiary) }
            if let diagnostic {
                // 「被遮蔽」= 前面的同 kind+value（或更宽的域名/IP）先命中；
                // 「不可达」= 排在非取反 MATCH 之后。两种死法分开标，原因在 help 里。
                Badge(text: Self.diagnosticLabel(diagnostic.kind), color: LP.danger)
                    .help(diagnostic.reason)
            }
            Spacer()
            Text(rule.policy)
                .font(LPFont.mono(10, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(policyColor)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private var label: String {
        switch rule.kind {
        case .domain: return "DOMAIN"
        case .domainSuffix: return "SUFFIX"
        case .domainKeyword: return "KEYWORD"
        case .domainRegex: return "REGEX"
        case .ipCIDR: return "IP-CIDR"
        case .ipCIDR6: return "IP-CIDR6"
        case .srcIPCIDR: return "SRC-IP"
        case .processName: return "PROCESS"
        case .geoIP: return "GEOIP"
        case .ruleSet: return "RULESET"
        case .and: return "AND"
        case .or: return "OR"
        case .not: return "NOT"
        case .match: return "MATCH"
        }
    }
    /// 一类死法一个标签：只写「永不命中」看不出是被前面那条盖住，还是排在 MATCH 之后。
    static func diagnosticLabel(_ kind: RuleDiagnostic.Kind) -> String {
        switch kind {
        case .shadowed: return "被遮蔽"
        case .duplicate: return "重复"
        case .unreachable: return "不可达"
        case .ruleSetMissing: return "规则集缺失"
        case .neverMatch: return "永不命中"
        }
    }

    /// 类型一律中性：表格里只有「策略」携带信息，且用墨阶而非彩色。
    private var color: Color { LP.textSecondary }

    /// 策略墨阶：PROXY = 满墨、DIRECT = secondary、REJECT = 朱红。
    /// 朱红因此只代表「拦截」，不再和主按钮抢同一个语义；层级靠字重与基准色，不靠低透明度。
    private var policyColor: Color {
        let p = rule.policy.uppercased()
        if p == "REJECT" { return LP.danger }
        if p == "DIRECT" { return LP.textSecondary }
        return LP.text
    }
}

@MainActor
struct AddRuleSheet: View {
    @ObservedObject private var engine = LeapinEngine.shared
    var onAdd: (Rule) -> Void
    var onCancel: () -> Void

    @State private var kind: RuleKind = .domainSuffix
    @State private var value = ""
    @State private var policy = "PROXY"
    @State private var noResolve = false
    @FocusState private var valueFocused: Bool

    private var policies: [String] {
        var names = ["DIRECT", "REJECT"]
        names += engine.profile.groups.map(\.name)
        names += engine.profile.outbounds.map(\.name).filter { !names.contains($0) }
        return Array(NSOrderedSet(array: names)) as? [String] ?? names
    }

    private var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Inline validation: add button stays disabled and the reason is visible.
    private var validationError: String? {
        guard !trimmedValue.isEmpty else { return nil }
        switch kind {
        case .domain, .domainSuffix:
            let pattern = #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"#
            if trimmedValue.range(of: pattern, options: .regularExpression) == nil {
                return "域名格式不正确，例如 api.spotify.com"
            }
        case .ipCIDR, .ipCIDR6, .srcIPCIDR:
            if !trimmedValue.contains("/") { return "CIDR 需要包含前缀长度，例如 10.0.0.0/8" }
        case .geoIP:
            if trimmedValue.count != 2 { return "GEOIP 使用两位国家代码，例如 CN" }
        case .ruleSet:
            if !(trimmedValue.hasPrefix("http://") || trimmedValue.hasPrefix("https://")) {
                return "规则集需要 http(s) URL"
            }
        default:
            break
        }
        if engine.profile.rules.contains(where: {
            $0.kind == kind && $0.value == trimmedValue && $0.policy == policy
        }) {
            return "相同规则已存在"
        }
        return nil
    }

    private var canAdd: Bool { !trimmedValue.isEmpty && validationError == nil }

    /// Would this rule be dead on arrival? Same conservative scan as the list,
    /// so the sheet warns before the rule is added instead of after.
    private var draftWarning: String? {
        guard validationError == nil else { return nil }
        let raw = "\(kind.rawValue.uppercased()),\(trimmedValue),\(policy)" + (noResolve ? ",no-resolve" : "")
        let draft = Rule(kind: kind, value: trimmedValue, policy: policy,
                         modifiers: noResolve ? ["no-resolve"] : [], raw: raw)
        let position = engine.profile.rules.count
        let scan = engine.ruleDiagnostics(for: engine.profile.rules + [draft])
        guard let diagnostic = scan.first(where: { $0.index == position }) else { return nil }
        return "添加后永不命中：\(diagnostic.reason)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LPEyebrow(text: "新建规则 / New rule")
                .padding(.bottom, 7)
            Text("添加分流规则")
                .font(LPFont.display(20, weight: .semibold))
                .tracking(-0.5)
                .foregroundStyle(LP.text)
                .padding(.bottom, 18)

            formRow("类型") {
                LPSelectField(value: $kind,
                              options: RuleKind.allCases
                                .filter { $0 != .and && $0 != .or && $0 != .not }
                                .map { ($0, $0.rawValue.uppercased()) })
            }
            formRow("匹配值") {
                LPLineField(text: $value, placeholder: placeholder)
                    .focused($valueFocused)
            }
            formRow("策略") {
                LPSelectField(value: $policy, options: policies.map { ($0, $0) })
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("不做 DNS 解析")
                        .font(.system(size: 13))
                        .foregroundStyle(LP.text)
                    Text("no-resolve，IP 规则常用")
                        .font(.system(size: 13))
                        .foregroundStyle(LP.textTertiary)
                }
                Spacer(minLength: 12)
                LPSwitch(isOn: $noResolve, width: 32)
            }
            .padding(.vertical, 9)

            if let validationError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    Text(validationError).font(.system(size: 13))
                }
                .foregroundStyle(LP.danger)
                .padding(.top, 8)
            }

            if let draftWarning {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "eye.slash.fill").font(.system(size: 11))
                    Text(draftWarning)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(LP.textSecondary)
                .padding(.top, 8)
            }

            if !trimmedValue.isEmpty {
                Text("\(kind.rawValue.uppercased()), \(trimmedValue), \(policy)" + (noResolve ? ", no-resolve" : ""))
                    .font(LPFont.mono(11))
                    .foregroundStyle(LP.textTertiary)
                    .lineLimit(1)
                    .padding(.top, 10)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                    .buttonStyle(LPGhostButtonStyle())
                Button("添加") {
                    let raw = "\(kind.rawValue.uppercased()),\(trimmedValue),\(policy)" + (noResolve ? ",no-resolve" : "")
                    let rule = Rule(kind: kind, value: trimmedValue, policy: policy,
                                    modifiers: noResolve ? ["no-resolve"] : [], raw: raw)
                    onAdd(rule)
                }
                .buttonStyle(LPPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 500)
        .onAppear { DispatchQueue.main.async { valueFocused = true } }
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .font(LPFont.mono(10, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(LP.textTertiary)
                .frame(width: 52, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LP.stroke.opacity(0.55)).frame(height: 0.5)
        }
    }

    private var placeholder: String {
        switch kind {
        case .domain: return "example.com"
        case .domainSuffix: return "example.com"
        case .domainKeyword: return "ads"
        case .ipCIDR: return "10.0.0.0/8"
        case .processName: return "Spotify"
        case .geoIP: return "CN"
        case .ruleSet: return "https://example.com/rules.list"
        default: return "值"
        }
    }
}
