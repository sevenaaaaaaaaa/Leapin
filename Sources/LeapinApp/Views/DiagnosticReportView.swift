import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LeapinRuntime

/// 诊断结果卡。它不是一页：只作为「为什么 · 诊断」工作区内部的结果，工作区把
/// 「重新检查」传进来，卡片就地重测，不用回到输入框（T-12）。
@MainActor
struct DiagnosticReportView: View {
    @EnvironmentObject private var app: AppModel
    let report: NetworkDiagnosticReport
    /// 工作区提供的原地重测动作；独立使用时为 nil，卡片不显示这个按钮。
    var onRetest: (() -> Void)? = nil
    @State private var copied = false
    @State private var exported: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(report.problemCount > 0 ? "\(report.problemCount) 项待处理" : "本次检查结果", systemImage: "list.bullet.clipboard")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(report.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 13)).foregroundStyle(LP.textSecondary)
                if let onRetest {
                    Button("重新检查") { onRetest() }.buttonStyle(LPGhostButtonStyle()).disabled(app.networkBusy)
                }
                Button(exported == nil ? "导出报告…" : "已导出") { export() }.buttonStyle(LPGhostButtonStyle())
                Button(copied ? "已复制摘要" : "复制检查摘要") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report.copyText, forType: .string); copied = true
                }.buttonStyle(LPGhostButtonStyle())
            }
            if let exported {
                Text("已写入 \(exported.lastPathComponent)").font(.system(size: 11)).foregroundStyle(LP.textTertiary)
            }
            if report.profileID != app.engine.profile.id {
                Text("当前已切换配置，以下是之前方案的检查结果。").font(.system(size: 13)).foregroundStyle(LP.danger)
            }
            ForEach(report.findings) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.isProblem ? "exclamationmark.circle" : "info.circle").foregroundStyle(item.isProblem ? LP.danger : LP.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.system(size: 13, weight: .semibold))
                        Text(item.detail).font(.system(size: 13)).foregroundStyle(LP.textSecondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    if item.action != .none {
                        Button(actionTitle(item.action)) { act(item.action) }.buttonStyle(LPGhostButtonStyle()).disabled(app.networkBusy)
                    }
                }
                LPDivider()
            }
            Text("日志线索 · Leapin 最近 15 分钟内至多 300 条；Mihomo 当前进程末尾至多 100 行。可能包含更早配置的事件，不等于本次请求根因。")
                .font(.system(size: 13)).foregroundStyle(LP.textTertiary).fixedSize(horizontal: false, vertical: true)
            if report.logClusters.isEmpty {
                Text("范围内未提取到已知错误线索；这不代表所有网络路径都正常。")
                    .font(.system(size: 13)).foregroundStyle(LP.textSecondary)
            }
            ForEach(report.logClusters) { cluster in
                DisclosureGroup("\(cluster.source) · \(cluster.kind) · \(cluster.count) 条") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(cluster.first.map { "最早 \($0.formatted(date: .omitted, time: .standard)) · 最晚 \((cluster.last ?? $0).formatted(date: .omitted, time: .standard))" } ?? "未解析内核事件时间，不作为近期故障证据。")
                        Text(cluster.sample).font(LPFont.mono(11)).textSelection(.enabled)
                        Text("本地日志样例已做常见凭据脱敏，复制检查摘要不包含原始日志。")
                    }.font(.system(size: 13)).foregroundStyle(LP.textSecondary).padding(.top, 8)
                }.font(.system(size: 13))
            }
        }.padding(20).foregroundStyle(LP.text).lpPanel(padding: 0)
    }
    /// 报告导出成一份 .md：摘要 + 逐条发现，全部是本地已有的事实，不新发请求。
    private func export() {
        let stamp = report.date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let panel = NSSavePanel()
        // .md 优先：文件内容是 Markdown；系统没有对应类型时退回纯文本（T-14 评审 O4）。
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Leapin-诊断-\(stamp).md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let body = "# Leapin 诊断报告\n\n\(report.date.formatted(date: .abbreviated, time: .standard))\n\n\(report.copyText)\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            exported = url
        } catch {
            // 写盘失败要说话：静默回到「导出报告…」会让人以为文件在（取消与失败读起来一样）。
            exported = nil
            app.showToast("报告没写成：\(error.localizedDescription)", kind: .error)
        }
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
