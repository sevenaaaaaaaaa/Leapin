import SwiftUI
import LeapinControl

/// 策略: one section per group, one row per member, a checkmark on the active one.
struct PoliciesView: View {
    @Environment(ConsoleStore.self) private var store
    @State private var pending: PendingSelection?

    struct PendingSelection: Identifiable {
        let id = UUID()
        var group: String
        var outbound: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.policies.isEmpty {
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
            .background(LP.groupedBackground)
            .contentMargins(.bottom, 84, for: .scrollContent)
            .navigationTitle("策略")
            .navigationBarTitleDisplayMode(.large)
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
