import SwiftUI
import LeapinControl

/// 连接 in the system-native shape: one searchable list of rows, policy as the
/// right-aligned value, no card chrome.
struct ConnectionsView: View {
    @Environment(ConsoleStore.self) private var store
    private var local: LocalProxyEngine { .shared }
    @State private var query = ""
    @State private var showGuide = false

    /// The phone's own traffic when its engine runs, the Mac's list otherwise.
    private var source: [ControlConnection] {
        local.isRunning && !local.localConnections.isEmpty ? local.localConnections : store.connections
    }

    private var filtered: [ControlConnection] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return source }
        let needle = query.lowercased()
        return source.filter {
            $0.host.lowercased().contains(needle)
                || $0.sourceApp.lowercased().contains(needle)
                || $0.policy.lowercased().contains(needle)
                || $0.outbound.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if filtered.isEmpty {
                    emptyState
                } else {
                    LPSection(header: local.isRunning ? "本机 \(filtered.count) 条" : "来自 Mac") {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, connection in
                            row(connection, isLast: index == filtered.count - 1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .background(LP.groupedBackground)
            .contentMargins(.bottom, 84, for: .scrollContent)
            .navigationTitle("连接")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "搜索域名、App 或策略")
            .refreshable { await store.refresh() }
            .sheet(isPresented: $showGuide) { LocalProxyGuide() }
        }
    }

    private func row(_ connection: ControlConnection, isLast: Bool) -> some View {
        LPListRow(title: connection.host,
                  subtitle: subtitle(connection),
                  value: connection.policy, mono: false, isLast: isLast) {
            Text(LPFormat.bytes(connection.bytesIn) + " ↓")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(LP.textTertiary)
        }
    }

    private func subtitle(_ connection: ControlConnection) -> String {
        var parts: [String] = []
        if connection.port != 443 { parts.append(":\(connection.port)") }
        if !connection.sourceApp.isEmpty { parts.append(connection.sourceApp) }
        if !connection.outbound.isEmpty { parts.append(connection.outbound) }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(LP.textTertiary)
            Text(local.isRunning ? "还没有流量经过本机引擎" : "本机引擎没在跑")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LP.text)
            Text(local.isRunning
                 ? "系统代理还没指向 127.0.0.1:" + String(local.port) + "。填好后，经过它的连接会出现在这里。"
                 : "先在「状态」页打开本机引擎，再把系统代理指过来。")
                .font(.system(size: 13))
                .foregroundStyle(LP.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
            if local.isRunning {
                Button("怎么设置系统代理") { showGuide = true }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LP.accent)
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }
}
