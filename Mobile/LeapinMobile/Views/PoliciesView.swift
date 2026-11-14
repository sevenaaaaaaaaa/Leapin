import SwiftUI
import LeapinControl

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
            Group {
                if store.policies.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.policies, id: \.name) { group in
                                groupCard(group)
                            }
                        }
                        .lpPage()
                    }
                    .background(LP.canvas)
                }
            }
            .navigationTitle("策略")
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

    private func groupCard(_ group: ControlPolicyGroup) -> some View {
        LPCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .font(LPFont.display(15, weight: .semibold))
                            .foregroundStyle(LP.text)
                        Text(typeLabel(group.type))
                            .font(LPFont.micro)
                            .foregroundStyle(LP.textTertiary)
                    }
                    Spacer(minLength: 4)
                    LPPill(text: group.effective.isEmpty ? group.selected : group.effective,
                           tint: LP.accent, filled: true)
                }

                if group.selected != group.effective && !group.effective.isEmpty {
                    Text("已选 \(group.selected)，实际走 \(group.effective)")
                        .font(LPFont.micro)
                        .foregroundStyle(LP.amber)
                }

                if !group.members.isEmpty {
                    Divider().overlay(LP.stroke)
                    FlowRow(spacing: 6) {
                        ForEach(group.members, id: \.self) { member in
                            Button {
                                guard member != group.selected else { return }
                                pending = PendingSelection(group: group.name, outbound: member)
                            } label: {
                                memberChip(member, isSelected: member == group.selected)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func memberChip(_ name: String, isSelected: Bool) -> some View {
        Text(name)
            .font(LPFont.micro)
            .foregroundStyle(isSelected ? .white : LP.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? LP.accentFill : LP.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.clear : LP.stroke, lineWidth: 1)
            )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(LP.textTertiary)
            Text("没有策略组")
                .font(LPFont.section)
                .foregroundStyle(LP.text)
            Text("在 Mac 的配置里添加代理组后会自动出现")
                .font(LPFont.caption)
                .foregroundStyle(LP.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LP.canvas)
    }

    private func typeLabel(_ type: String) -> String {
        switch type.lowercased() {
        case "select": return "手动选择"
        case "urltest", "fallback": return "自动测速"
        case "loadbalance": return "负载均衡"
        default: return type.isEmpty ? "代理组" : type
        }
    }
}

/// Minimal wrapping stack: iOS 17 has no built-in flow layout.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
