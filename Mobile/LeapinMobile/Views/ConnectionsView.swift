import SwiftUI
import LeapinControl

/// 连接 in the system-native shape: one searchable list of rows, policy as the
/// right-aligned value, no card chrome.
struct ConnectionsView: View {
    @Environment(ConsoleStore.self) private var store
    private var local: LocalProxyEngine { .shared }
    @State private var query = ""
    @State private var showGuide = false
    /// v6：时间河冻结与列表过滤条（按 Surge 的做法，过滤压在列表上方）。
    @State private var frozen: Int?
    @State private var filter: ConnectionFilter = .all

    private var feed: LPRiverFeed { .shared }

    private enum ConnectionFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case proxy = "代理"
        case direct = "直连"

        var id: String { rawValue }

        func matches(_ connection: ControlConnection) -> Bool {
            let direct = connection.policy.uppercased() == "DIRECT"
                || connection.outbound.uppercased() == "DIRECT"
            switch self {
            case .all: return true
            case .proxy: return !direct
            case .direct: return direct
            }
        }
    }

    /// The phone's own traffic when its engine runs, the Mac's list otherwise.
    private var source: [ControlConnection] {
        local.isRunning && !local.localConnections.isEmpty ? local.localConnections : store.connections
    }

    private var filtered: [ControlConnection] {
        let byKind = source.filter { filter.matches($0) }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return byKind }
        let needle = query.lowercased()
        return byKind.filter {
            $0.host.lowercased().contains(needle)
                || $0.sourceApp.lowercased().contains(needle)
                || $0.policy.lowercased().contains(needle)
                || $0.outbound.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LPPageHeader(title: "连接",
                             status: local.isRunning
                                ? "本机 \(filtered.count) 条"
                                : (store.endpoint == nil ? "未配对 · 只看本机" : "来自 Mac \(filtered.count) 条"))
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                riverBlock
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                filterBar
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
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
            .background(LP.canvas)
            .contentMargins(.bottom, 120, for: .scrollContent)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索域名、App 或策略")
            .refreshable { await store.refresh() }
            .task { feed.start() }
            .sheet(isPresented: $showGuide) { LocalProxyGuide() }
        }
    }

    private var riverBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            LPRiver(samples: feed.samples, frozenIndex: frozen, enabled: local.isRunning,
                    onInk: false, height: 40) { index in
                frozen = index
            }
            HStack(spacing: 6) {
                Text(frozen.map { "−\(max(0, feed.samples.count - 1 - $0))s · 回看中" }
                     ?? (local.isRunning ? "最近 60 秒" : "引擎已停止"))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(LP.textTertiary)
                Spacer(minLength: 6)
                if frozen != nil {
                    Button("回到现在") { frozen = nil }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LP.accent)
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(LP.panel, in: RoundedRectangle(cornerRadius: LP.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LP.radius, style: .continuous)
                .strokeBorder(LP.stroke, lineWidth: 1)
        )
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(ConnectionFilter.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { filter = item }
                    LPHaptic.select()
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(filter == item ? LP.onInk : LP.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(filter == item ? LP.ink : LP.panel))
                        .overlay(Capsule().strokeBorder(filter == item ? Color.clear : LP.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.rawValue)请求")
            }
            Spacer(minLength: 6)
            Text("\(filtered.count) 条")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(LP.textTertiary)
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
