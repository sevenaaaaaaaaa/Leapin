import SwiftUI
import LeapinControl

struct ConnectionsView: View {
    @Environment(ConsoleStore.self) private var store
    @State private var query = ""

    private var filtered: [ControlConnection] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return store.connections }
        let needle = query.lowercased()
        return store.connections.filter {
            $0.host.lowercased().contains(needle)
                || $0.sourceApp.lowercased().contains(needle)
                || $0.policy.lowercased().contains(needle)
                || $0.outbound.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.connections.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filtered, id: \.id) { connection in
                                ConnectionRow(connection: connection)
                            }
                            if filtered.isEmpty {
                                Text("没有匹配「\(query)」的连接")
                                    .font(LPFont.caption)
                                    .foregroundStyle(LP.textTertiary)
                                    .padding(.top, 24)
                            }
                        }
                        .lpPage()
                    }
                    .background(LP.canvas)
                }
            }
            .navigationTitle("连接")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索域名、App 或策略")
            .refreshable { await store.refresh() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(LP.textTertiary)
            Text("还没有连接记录")
                .font(LPFont.section)
                .foregroundStyle(LP.text)
            Text("在 Mac 上访问任意网站，这里会实时出现")
                .font(LPFont.caption)
                .foregroundStyle(LP.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LP.canvas)
    }
}

struct ConnectionRow: View {
    let connection: ControlConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(connection.host)
                    .font(LPFont.display(14, weight: .medium))
                    .foregroundStyle(LP.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if connection.port != 443 {
                    Text(":\(connection.port)")
                        .font(LPFont.mono(11))
                        .foregroundStyle(LP.textTertiary)
                }
                Spacer(minLength: 4)
                LPPill(text: connection.policy, tint: policyTint(connection.policy))
            }

            HStack(spacing: 10) {
                Label(connection.sourceApp.isEmpty ? "未知来源" : connection.sourceApp,
                      systemImage: "app.dashed")
                    .font(LPFont.micro)
                    .foregroundStyle(LP.textSecondary)
                    .lineLimit(1)

                Label(connection.outbound.isEmpty ? connection.chainSummary : connection.outbound,
                      systemImage: "arrow.triangle.branch")
                    .font(LPFont.micro)
                    .foregroundStyle(LP.textTertiary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text("\(LPFormat.bytes(connection.bytesIn)) ↓ / \(LPFormat.bytes(connection.bytesOut)) ↑")
                    .font(LPFont.mono(10))
                    .foregroundStyle(LP.textTertiary)
            }

            if !connection.matchedRule.isEmpty {
                Text(connection.matchedRule)
                    .font(LPFont.mono(10))
                    .foregroundStyle(LP.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LP.panel, in: RoundedRectangle(cornerRadius: LP.radiusSmall + 2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LP.radiusSmall + 2, style: .continuous)
                .strokeBorder(LP.stroke, lineWidth: 1)
        )
    }

    private func policyTint(_ policy: String) -> Color {
        switch policy.lowercased() {
        case "proxy", "global", "proxy-group": return LP.accent
        case "direct": return LP.mint
        case "reject", "block": return LP.danger
        default: return LP.violet
        }
    }
}
