import SwiftUI
import TouchFlowCore
import TouchFlowRuntime
import TouchFlowPolicy
import TouchFlowNet
import TouchFlowIntegrations

@MainActor
struct RulesView: View {
    @ObservedObject private var engine = TouchFlowEngine.shared
    @State private var search = ""
    @State private var showAdd = false
    @State private var selection: String?

    private var filtered: [Rule] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return engine.profile.rules }
        return engine.profile.rules.filter {
            $0.raw.lowercased().contains(q) || $0.value.lowercased().contains(q) || $0.policy.lowercased().contains(q)
        }
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
            } onCancel: { showAdd = false }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.textTertiary)
                TextField("搜索域名 / 策略 / 原始规则", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(TF.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .frame(maxWidth: 330)

            Text("\(filtered.count) / \(engine.profile.rules.count)")
                .font(TFFont.num(10.5, weight: .medium))
                .foregroundStyle(TF.textTertiary)
            Spacer()
            Button {
                Task { await engine.reloadProfile() }
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
                EmptyHint(icon: "list.bullet.rectangle", text: engine.profile.rules.isEmpty ? "还没有规则，点击右上角添加，或从配置页导入 Clash / Surge 配置" : "没有匹配的规则")
            } else {
                List {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, rule in
                        RuleRow(index: index + 1, rule: rule)
                            .listRowSeparator(.hidden)
                            .contextMenu {
                                Button("删除规则", role: .destructive) { engine.removeRule(id: rule.id) }
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .padding(.vertical, 6)
            }
        }
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
            }
            .padding(14)
        }
        .background(TF.panel.opacity(0.35))
    }

    private func color(for type: OutboundType) -> Color {
        switch type {
        case .direct: return TF.mint
        case .reject: return TF.danger
        case .http, .socks5: return TF.accent
        case .shadowsocks, .trojan: return TF.violet
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

    private var policies: [String] {
        var names = ["DIRECT", "REJECT"]
        names += engine.profile.groups.map(\.name)
        names += engine.profile.outbounds.map(\.name).filter { !names.contains($0) }
        return Array(NSOrderedSet(array: names)) as? [String] ?? names
    }

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
                TextField(placeholder, text: $value).textFieldStyle(.roundedBorder)
            }
            LabeledField(label: "策略") {
                Picker("", selection: $policy) {
                    ForEach(policies, id: \.self) { Text($0).tag($0) }
                }.labelsHidden()
            }
            Toggle("不做 DNS 解析（no-resolve）", isOn: $noResolve).font(.callout)
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                    .buttonStyle(TFGhostButtonStyle())
                Button("添加") {
                    let raw = "\(kind.rawValue.uppercased()),\(value),\(policy)" + (noResolve ? ",no-resolve" : "")
                    let rule = Rule(kind: kind, value: value, policy: policy,
                                    modifiers: noResolve ? ["no-resolve"] : [], raw: raw)
                    onAdd(rule)
                }
                .buttonStyle(TFPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 470)
        .background(TF.panelSolid)
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
