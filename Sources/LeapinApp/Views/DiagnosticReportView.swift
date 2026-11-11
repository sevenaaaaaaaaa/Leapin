import SwiftUI
import AppKit
import LeapinRuntime

@MainActor
struct DiagnosticReportView: View {
    @EnvironmentObject private var app: AppModel
    let report: NetworkDiagnosticReport
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(report.problemCount > 0 ? "\(report.problemCount) 项待处理" : "本次检查结果", systemImage: "list.bullet.clipboard")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(report.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                Button(copied ? "已复制摘要" : "复制检查摘要") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report.copyText, forType: .string); copied = true
                }.buttonStyle(LPGhostButtonStyle())
            }
            if report.profileID != app.engine.profile.id {
                Text("当前已切换配置，以下是之前方案的检查结果。").font(.system(size: 12)).foregroundStyle(LP.danger)
            }
            ForEach(report.findings) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.isProblem ? "exclamationmark.circle" : "info.circle").foregroundStyle(item.isProblem ? LP.danger : LP.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.system(size: 13, weight: .semibold))
                        Text(item.detail).font(.system(size: 12)).foregroundStyle(LP.textSecondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    if item.action != .none {
                        Button(actionTitle(item.action)) { act(item.action) }.buttonStyle(LPGhostButtonStyle()).disabled(app.networkBusy)
                    }
                }
                LPDivider()
            }
            Text("日志线索 · Leapin 最近 15 分钟内至多 300 条；Mihomo 当前进程末尾至多 100 行。可能包含更早配置的事件，不等于本次请求根因。")
                .font(.system(size: 12)).foregroundStyle(LP.textTertiary).fixedSize(horizontal: false, vertical: true)
            if report.logClusters.isEmpty {
                Text("范围内未提取到已知错误线索；这不代表所有网络路径都正常。")
                    .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
            }
            ForEach(report.logClusters) { cluster in
                DisclosureGroup("\(cluster.source) · \(cluster.kind) · \(cluster.count) 条") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(cluster.first.map { "最早 \($0.formatted(date: .omitted, time: .standard)) · 最晚 \((cluster.last ?? $0).formatted(date: .omitted, time: .standard))" } ?? "未解析内核事件时间，不作为近期故障证据。")
                        Text(cluster.sample).font(LPFont.mono(11)).textSelection(.enabled)
                        Text("本地日志样例已做常见凭据脱敏，复制检查摘要不包含原始日志。")
                    }.font(.system(size: 12)).foregroundStyle(LP.textSecondary).padding(.top, 8)
                }.font(.system(size: 12))
            }
        }.padding(20).foregroundStyle(LP.text).lpPanel(padding: 0)
    }
    private func actionTitle(_ action: DiagnosticAction) -> String {
        switch action {
        case .connect: return "连接网络"
        case .settings: return "查看设置"
        case .capture: return "查看抓包"
        case .debugChannel: return "独立调试"
        case .profiles: return "查看方案"
        case .none: return ""
        }
    }
    private func act(_ action: DiagnosticAction) {
        switch action {
        case .connect: app.connectNetwork()
        case .settings: app.go(to: .settings)
        case .capture: app.go(to: .capture)
        case .debugChannel: app.networkToolPage = 1; app.showNetworkTools = true
        case .profiles: app.go(to: .profiles)
        case .none: break
        }
    }
}
