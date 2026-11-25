import SwiftUI
import LeapinControl

/// 策略: one section per group, one row per member, a checkmark on the active one.
struct PoliciesView: View {
    @Environment(ConsoleStore.self) private var store
    private var local: LocalProxyEngine { .shared }
    @State private var pending: PendingSelection?

    struct PendingSelection: Identifiable {
        let id = UUID()
        var group: String
        var outbound: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LPPageHeader(title: "策略",
                             status: store.endpoint == nil
                                ? "未配对 · 全部直连"
                                : "\(store.policies.count) 个策略组")
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                if store.endpoint == nil {
                    unpairedCard
                } else if store.policies.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(store.policies, id: \.name) { group in
                            section(group)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .background(LP.canvas)
            .contentMargins(.bottom, 120, for: .scrollContent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.loadPolicies() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                if store.policies.isEmpty { await store.loadPolicies() }
            }
            .confirmationDialog(
                pending.map { "切换到 \($0.outbound)？" } ?? "",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible
            ) {
                if let pending {
                    Button("切换到 \(pending.outbound)") {
                        Task {
                            _ = await store.select(group: pending.group, outbound: pending.outbound)
                            self.pending = nil
                        }
                    }
                    Button("取消", role: .cancel) { self.pending = nil }
                }
            } message: {
                if let pending {
                    Text("\(pending.group) 会立即改用该节点，影响所有走这条策略的连接。")
                }
            }
        }
    }

    private func section(_ group: ControlPolicyGroup) -> some View {
        let active = group.effective.isEmpty ? group.selected : group.effective
        let footer = group.selected != group.effective && !group.effective.isEmpty
            ? "已选 \(group.selected)，实际走 \(group.effective)"
            : typeLabel(group.type)
        return LPSection(header: group.name, footer: footer) {
            if group.members.isEmpty {
                LPListRow(title: active.isEmpty ? "没有成员" : active, isLast: true)
            } else {
                ForEach(Array(group.members.enumerated()), id: \.element) { index, member in
                    LPListRow(title: member,
                              value: member == active ? "当前" : nil,
                              isLast: index == group.members.count - 1) {
                        if member == active {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LP.accent)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard member != active else { return }
                        pending = PendingSelection(group: group.name, outbound: member)
                    }
                }
            }
        }
    }

    /// 未配对时不是空白：讲清本机怎么走，并给一个能立刻做的动作。
    private var unpairedCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            LPSection(header: "未配对时的走法",
                      footer: "规则与出口来自 Mac 的配置；配对后这里会出现分组与当前出口。") {
                LPListRow(title: "分流", value: "全部直连", isLast: false)
                LPListRow(title: "引擎",
                          value: local.isRunning ? "127.0.0.1:" + String(local.port) : "未启动",
                          mono: local.isRunning,
                          isLast: true) {
                    Button(local.isChecking ? "…" : "自检") { Task { await local.selfCheck() } }
                        .font(.system(size: 15))
                        .foregroundStyle(LP.accent)
                        .buttonStyle(.plain)
                        .disabled(!local.isRunning || local.isChecking)
                }
            }

            if let check = local.lastCheck {
                Text(check)
                    .font(LPFont.micro)
                    .foregroundStyle(LP.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }

            Button("配对 Mac") { store.pairingSheetShown = true }
                .buttonStyle(LPButtonStyle())
                .padding(.horizontal, 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(LP.textTertiary)
            Text("没有策略组")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LP.text)
            Text("在 Mac 的配置里添加代理组后会自动出现")
                .font(.system(size: 13))
                .foregroundStyle(LP.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private func typeLabel(_ type: String) -> String {
        switch type.lowercased() {
        case "select": return "手动选择"
        case "url-test": return "自动测速"
        case "fallback": return "故障转移"
        case "load-balance": return "负载均衡"
        default: return type
        }
    }
}
