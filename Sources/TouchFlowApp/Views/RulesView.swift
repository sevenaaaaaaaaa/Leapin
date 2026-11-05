import SwiftUI
import TouchFlowCore
import TouchFlowRuntime
import TouchFlowPolicy
import TouchFlowNet
import TouchFlowIntegrations

@MainActor
struct RulesView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var engine = TouchFlowEngine.shared
    @State private var search = ""
    @State private var showAdd = false
    @State private var selection: String?
    @State private var pendingDelete: Rule?
    @State private var filter: PolicyFilter = .all
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

    private var filtered: [Rule] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return engine.profile.rules.filter { rule in
            guard filter.matches(rule) else { return false }
            guard !q.isEmpty else { return true }
            return rule.raw.lowercased().contains(q)
                || rule.value.lowercased().contains(q)
                || rule.policy.lowercased().contains(q)
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
            toolbar
            HStack(alignment: .top, spacing: 22) {
                ruleList
                    .background(TF.panel, in: RoundedRectangle(cornerRadius: TF.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: TF.radius, style: .continuous).strokeBorder(TF.stroke, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: TF.radius, style: .continuous))
                sidePanel.frame(width: 292)
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("分流规则")
        .sheet(isPresented: $showAdd) {
            AddRuleSheet { rule in
                engine.addRules([rule])
                showAdd = false
                app.showToast("已添加规则 \(rule.value)")
            } onCancel: { showAdd = false }
        }
        .tfConfirm("删除这条规则？",
                   message: pendingDelete.map { "\($0.kind.rawValue.uppercased()),\($0.value),\($0.policy)\n删除后立即生效，可通过重新导入配置恢复。" } ?? "",
                   isPresented: Binding(
                       get: { pendingDelete != nil },
                       set: { if !$0 { pendingDelete = nil } }
                   ),
                   confirmTitle: "删除") {
            guard let rule = pendingDelete else { return }
            engine.removeRule(id: rule.id)
            if selection == rule.id { selection = nil }
            pendingDelete = nil
            app.showToast("已删除 \(rule.value)", kind: .info)
        }
        .onChange(of: app.searchFocusRequest) { _, _ in
            searchFocused = true
        }
        .onChange(of: search) { _, _ in
            if let selected = selection, !filtered.contains(where: { $0.id == selected }) {
                selection = nil
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TFSearchField(text: $search, placeholder: "搜索域名 / 策略 / 原始规则", width: 235, focus: $searchFocused)

            HStack(spacing: 5) {
                ForEach(PolicyFilter.allCases) { option in
                    TFChip(title: option.title, count: count(for: option), selected: filter == option) {
                        withAnimation(.easeOut(duration: 0.12)) { filter = option }
                    }
                }
            }

            Text("\(filtered.count) / \(engine.profile.rules.count)")
                .font(TFFont.num(10.5, weight: .medium))
                .foregroundStyle(TF.textTertiary)
            Spacer()
            Button {
                Task { await engine.reloadProfile() }
                app.showToast("配置已重新载入", kind: .info)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold))
                    Text("重载").font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(TFGhostButtonStyle())

            Button {
                showAdd = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    Text("添加规则").font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(TFPrimaryButtonStyle())
        }
        .padding(.horizontal, 32).padding(.vertical, 13)
        .background(TF.bg)
    }

    private var ruleList: some View {
        Group {
            if filtered.isEmpty {
                TFEmptyState(
                    icon: "list.bullet.rectangle",
                    title: engine.profile.rules.isEmpty ? "还没有规则" : "没有匹配的规则",
                    message: engine.profile.rules.isEmpty
                        ? "可以从配置页导入 Clash / Surge 配置，或手动添加第一条规则。"
                        : "换一个关键词，或把策略筛选切回“全部”。",
                    actionTitle: engine.profile.rules.isEmpty ? "添加规则" : "清除筛选",
                    action: {
                        if engine.profile.rules.isEmpty { showAdd = true }
                        else { search = ""; filter = .all }
                    })
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("#").frame(width: 30, alignment: .leading)
                        Text("类型").frame(width: 66, alignment: .leading)
                        Text("匹配值")
                        Spacer(minLength: 8)
                        Text("策略")
                    }
                    .font(TFFont.mono(9, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(TF.textTertiary)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 7)
                    Rectangle().fill(TF.stroke.opacity(0.7)).frame(height: 0.5)
                    ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, rule in
                            TFRow(selected: selection == rule.id,
                                  accessibilityText: "\(rule.kind.rawValue) \(rule.value) \(rule.policy)") {
                                selection = rule.id
                                listFocused = true
                            } content: {
                                RuleRow(index: index + 1, rule: rule)
                            }
                            .contextMenu {
                                Button("复制匹配值") {
                                    TFClipboard.copy(rule.value)
                                    app.showToast("已复制 \(rule.value)", kind: .info)
                                }
                                Button("复制原始规则") {
                                    TFClipboard.copy(rule.raw)
                                    app.showToast("已复制原始规则", kind: .info)
                                }
                                Divider()
                                Button("删除规则", role: .destructive) { pendingDelete = rule }
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
                        if let id = selection, let rule = engine.profile.rules.first(where: { $0.id == id }) {
                            pendingDelete = rule
                        }
                    }
                }
            }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !filtered.isEmpty else { return }
        let current = filtered.firstIndex(where: { $0.id == selection })
        let next: Int
        switch direction {
        case .up:
            next = max(0, (current ?? 0) - 1)
        case .down:
            next = min(filtered.count - 1, (current ?? -1) + 1)
        default:
            return
        }
        selection = filtered[next].id
    }

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                railSection("策略组 / GROUPS") {
                    if engine.profile.groups.isEmpty {
                        railNote("当前配置没有策略组")
                    } else {
                        ForEach(engine.profile.groups) { group in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 7) {
                                    Text(group.name)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(TF.text)
                                    Spacer()
                                    Text(group.type.rawValue.uppercased())
                                        .font(TFFont.mono(8.5))
                                        .tracking(0.6)
                                        .foregroundStyle(TF.textTertiary)
                                }
                                TFSelectField(value: Binding(
                                    get: { group.selected ?? group.proxies.first ?? "DIRECT" },
                                    set: { engine.selectOutbound(group: group.name, outbound: $0) }
                                ), options: group.proxies.map { ($0, $0) })
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                railRule

                railSection("出站 / OUTBOUNDS") {
                    ForEach(engine.profile.outbounds) { outbound in
                        HStack(spacing: 8) {
                            Circle().fill(color(for: outbound.type)).frame(width: 5, height: 5)
                            Text(outbound.name)
                                .font(.system(size: 12))
                                .foregroundStyle(TF.text)
                            Spacer()
                            Text(outbound.type.rawValue)
                                .font(TFFont.mono(8.5))
                                .foregroundStyle(TF.textTertiary)
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
                                .font(TFFont.mono(9.5))
                                .foregroundStyle(TF.textSecondary)
                                .lineLimit(1)
                        }
                        railNote("规则集在启动时下载/读取并缓存，失败会降级为空。")
                    }
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

    private func railSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            TFEyebrow(text: title)
            content()
        }
    }

    private var railRule: some View {
        Rectangle().fill(TF.stroke.opacity(0.8)).frame(height: 1)
    }

    private func railNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(TF.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func shortcut(_ key: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            TFKeyCap(keys: key)
            Text(label).font(.system(size: 10.5)).foregroundStyle(TF.textTertiary)
        }
    }

    private func color(for type: OutboundType) -> Color {
        switch type {
        case .direct: return TF.text.opacity(0.35)
        case .reject: return TF.danger
        default: return TF.text.opacity(0.65)
        }
    }
}

struct RuleRow: View {
    var index: Int
    var rule: Rule
    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)")
                .font(TFFont.mono(10))
                .foregroundStyle(TF.textTertiary)
                .frame(width: 30, alignment: .leading)
            Text(label)
                .font(TFFont.mono(10, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(TF.textTertiary)
                .lineLimit(1)
                .frame(width: 66, alignment: .leading)
            Text(rule.value)
                .font(TFFont.mono(11.5))
                .foregroundStyle(TF.text)
                .lineLimit(1)
            if rule.noResolve { Badge(text: "no-resolve", color: TF.textTertiary) }
            Spacer()
            Text(rule.policy)
                .font(TFFont.mono(10.5, weight: .semibold))
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
    /// 类型一律中性：表格里只有「策略」携带信息，且用墨阶而非彩色。
    private var color: Color { TF.textSecondary }

    /// 策略墨阶：PROXY = 满墨、DIRECT = secondary、REJECT = 朱红。
    /// 朱红因此只代表「拦截」，不再和主按钮抢同一个语义；层级靠字重与基准色，不靠低透明度。
    private var policyColor: Color {
        let p = rule.policy.uppercased()
        if p == "REJECT" { return TF.danger }
        if p == "DIRECT" { return TF.textSecondary }
        return TF.text
    }
}

@MainActor
struct AddRuleSheet: View {
    @ObservedObject private var engine = TouchFlowEngine.shared
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TFEyebrow(text: "新建规则 / NEW RULE")
                .padding(.bottom, 7)
            Text("添加分流规则")
                .font(TFFont.display(20, weight: .semibold))
                .tracking(-0.5)
                .foregroundStyle(TF.text)
                .padding(.bottom, 18)

            formRow("类型") {
                TFSelectField(value: $kind,
                              options: RuleKind.allCases
                                .filter { $0 != .and && $0 != .or && $0 != .not }
                                .map { ($0, $0.rawValue.uppercased()) })
            }
            formRow("匹配值") {
                TFLineField(text: $value, placeholder: placeholder)
                    .focused($valueFocused)
            }
            formRow("策略") {
                TFSelectField(value: $policy, options: policies.map { ($0, $0) })
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("不做 DNS 解析")
                        .font(.system(size: 12.5))
                        .foregroundStyle(TF.text)
                    Text("no-resolve，IP 规则常用")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.textTertiary)
                }
                Spacer(minLength: 12)
                TFSwitch(isOn: $noResolve, width: 32)
            }
            .padding(.vertical, 9)

            if let validationError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5))
                    Text(validationError).font(.system(size: 12))
                }
                .foregroundStyle(TF.danger)
                .padding(.top, 8)
            }

            if !trimmedValue.isEmpty {
                Text("\(kind.rawValue.uppercased()), \(trimmedValue), \(policy)" + (noResolve ? ", no-resolve" : ""))
                    .font(TFFont.mono(10))
                    .foregroundStyle(TF.textTertiary)
                    .lineLimit(1)
                    .padding(.top, 10)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                    .buttonStyle(TFGhostButtonStyle())
                Button("添加") {
                    let raw = "\(kind.rawValue.uppercased()),\(trimmedValue),\(policy)" + (noResolve ? ",no-resolve" : "")
                    let rule = Rule(kind: kind, value: trimmedValue, policy: policy,
                                    modifiers: noResolve ? ["no-resolve"] : [], raw: raw)
                    onAdd(rule)
                }
                .buttonStyle(TFPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 500)
        .background(TF.panelSolid)
        .onAppear { DispatchQueue.main.async { valueFocused = true } }
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .font(TFFont.mono(10, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(TF.textTertiary)
                .frame(width: 52, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TF.stroke.opacity(0.55)).frame(height: 0.5)
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
