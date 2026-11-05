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
            Divider()
            HStack(spacing: 16) {
                ruleList
                    .background(TF.panel, in: RoundedRectangle(cornerRadius: TF.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: TF.radius, style: .continuous).strokeBorder(TF.stroke, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: TF.radius, style: .continuous))
                sidePanel.frame(width: 286)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 18)
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
        .padding(.horizontal, 20).padding(.vertical, 11)
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
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
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
            VStack(alignment: .leading, spacing: 12) {
                Card(title: "策略组", icon: "square.stack.3d.up") {
                    if engine.profile.groups.isEmpty {
                        Text("当前配置没有策略组").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(engine.profile.groups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(group.name).font(.callout)
                                    Badge(text: group.type.rawValue, color: .blue)
                                    Spacer()
                                }
                                Picker("", selection: Binding(
                                    get: { group.selected ?? group.proxies.first ?? "DIRECT" },
                                    set: { engine.selectOutbound(group: group.name, outbound: $0) }
                                )) {
                                    ForEach(group.proxies, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden()
                                .controlSize(.small)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                Card(title: "出站", icon: "arrow.up.right.circle") {
                    ForEach(engine.profile.outbounds) { outbound in
                        HStack(spacing: 6) {
                            Circle().fill(color(for: outbound.type)).frame(width: 7, height: 7)
                            Text(outbound.name).font(.callout)
                            Spacer()
                            Text(outbound.type.rawValue).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Card(title: "规则集", icon: "shippingbox") {
                    let sets = engine.profile.rules.filter { $0.kind == .ruleSet }
                    if sets.isEmpty {
                        Text("未引用规则集").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(sets) { rule in
                            Text(rule.value).font(.caption.monospaced()).lineLimit(1)
                        }
                        Text("规则集在启动时下载/读取并缓存，失败会降级为空。").font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                Card(title: "快捷键", icon: "command") {
                    VStack(alignment: .leading, spacing: 6) {
                        shortcut("⌘F", "聚焦搜索")
                        shortcut("↑ ↓", "选择规则")
                        shortcut("⌫", "删除选中规则")
                        shortcut("⌘K", "命令面板")
                    }
                }
            }
            .padding(14)
        }
        .background(TF.panel.opacity(0.35))
    }

    private func shortcut(_ key: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            TFKeyCap(keys: key)
            Text(label).font(.system(size: 10.5)).foregroundStyle(TF.textTertiary)
        }
    }

    private func color(for type: OutboundType) -> Color {
        switch type {
        case .direct: return TF.mint
        case .reject: return TF.danger
        case .http, .socks5: return TF.accent
        case .shadowsocks, .trojan: return TF.violet
        default: return TF.textSecondary
        }
    }
}

struct RuleRow: View {
    var index: Int
    var rule: Rule
    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)")
                .font(TFFont.mono(9.5))
                .foregroundStyle(TF.textTertiary)
                .frame(width: 34, alignment: .trailing)
            Badge(text: label, color: color)
            Text(rule.value)
                .font(TFFont.mono(11))
                .foregroundStyle(TF.text)
                .lineLimit(1)
            if rule.noResolve { Badge(text: "no-resolve", color: TF.textTertiary) }
            Spacer()
            Text(rule.policy)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(policyColor)
        }
        .padding(.vertical, 5)
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
    private var color: Color {
        switch rule.kind {
        case .match: return TF.amber
        case .ruleSet: return TF.violet
        case .processName: return TF.mint
        case .geoIP, .ipCIDR, .ipCIDR6, .srcIPCIDR: return TF.accent
        default: return TF.accent
        }
    }
    private var policyColor: Color {
        let p = rule.policy.uppercased()
        if p == "REJECT" { return TF.danger }
        if p == "DIRECT" { return TF.mint }
        return TF.violet
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "plus.square.on.square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TF.accent)
                Text("添加分流规则")
                    .font(TFFont.display(15, weight: .bold))
                    .foregroundStyle(TF.text)
            }
            LabeledField(label: "类型") {
                Picker("", selection: $kind) {
                    ForEach(RuleKind.allCases, id: \.self) { k in
                        if k != .and && k != .or && k != .not {
                            Text(k.rawValue).tag(k)
                        }
                    }
                }.labelsHidden()
            }
            LabeledField(label: "匹配值") {
                TextField(placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .focused($valueFocused)
            }
            LabeledField(label: "策略") {
                Picker("", selection: $policy) {
                    ForEach(policies, id: \.self) { Text($0).tag($0) }
                }.labelsHidden()
            }
            Toggle("不做 DNS 解析（no-resolve）", isOn: $noResolve).font(.callout)

            if let validationError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5))
                    Text(validationError).font(.system(size: 10.5))
                }
                .foregroundStyle(TF.danger)
            }

            HStack {
                if !trimmedValue.isEmpty {
                    Text("\(kind.rawValue.uppercased()), \(trimmedValue), \(policy)")
                        .font(TFFont.mono(9.5))
                        .foregroundStyle(TF.textTertiary)
                        .lineLimit(1)
                }
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
        }
        .padding(22)
        .frame(width: 470)
        .background(TF.panelSolid)
        .onAppear { DispatchQueue.main.async { valueFocused = true } }
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
