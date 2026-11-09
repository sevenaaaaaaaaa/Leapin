import SwiftUI
import AppKit
import LeapinCore
import LeapinPolicy

/// 导入报告：把解析器实际看懂/跳过的内容如实列出来，而不是假装全部成功。
@MainActor
struct ImportReportSheet: View {
    let report: ImportReport
    var onClose: () -> Void

    @State private var copied = false

    private var blocking: Bool { report.issues.contains { $0.kind.isBlocking } }
    private var statusColor: Color { blocking ? LP.danger : report.isClean ? LP.mint : LP.amber }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            LPDivider()
            counters
            if !report.notDialable.isEmpty {
                LPDivider()
                notDialableBand
            }
            LPDivider()
            issueList
            LPDivider()
            footer
        }
        .frame(width: 580)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: blocking ? "exclamationmark.triangle" : report.isClean ? "checkmark.seal" : "exclamationmark.circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(statusColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 5) {
                LPEyebrow(blocking ? "IMPORT REPORT · BLOCKED" : "IMPORT REPORT", tint: LP.textTertiary)
                Text(blocking ? "导入未完成" : report.isClean ? "导入成功" : "导入完成，有需要留意的地方")
                    .font(LPFont.display(15, weight: .semibold))
                    .foregroundStyle(LP.text)
                Text(report.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var counters: some View {
        HStack(alignment: .top, spacing: 0) {
            counter("格式", report.format)
            counterDivider
            counter("出站", "\(report.outboundCount)")
            counterDivider
            counter("策略组", "\(report.groupCount)")
            counterDivider
            counter("规则", "\(report.ruleCount)")
            if report.skippedOutbounds > 0 {
                counterDivider
                counter("跳过", "\(report.skippedOutbounds)", tint: LP.amber)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func counter(_ label: String, _ value: String, tint: Color = LP.text) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LPEyebrow(label, tint: LP.textTertiary)
            Text(value)
                .font(LPFont.num(14, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(minWidth: 54, alignment: .leading)
    }

    /// Kept separate from the issue list on purpose: an outbound that was imported
    /// but cannot be dialed is the single most expensive silent failure on import.
    private var notDialableBand: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.slash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LP.amber)
                Text("\(report.notDialable.count) 个出站暂不可拨号")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LP.text)
                Spacer(minLength: 0)
            }
            Text(report.notDialable.joined(separator: "  ·  "))
                .font(LPFont.mono(10))
                .foregroundStyle(LP.textSecondary)
                .lineLimit(3)
                .textSelection(.enabled)
            Text("节点与协议都已保留（导出不会丢），但当前版本拨不出去；规则选到它们时连接会失败，可在策略组里换一个成员。")
                .font(.system(size: 11))
                .foregroundStyle(LP.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var counterDivider: some View {
        Rectangle()
            .fill(LP.stroke)
            .frame(width: 1, height: 28)
            .padding(.horizontal, 14)
    }

    private var issueList: some View {
        Group {
            if report.issues.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(LP.mint)
                    Text("所有字段都已识别，没有跳过任何内容。")
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(report.issues.enumerated()), id: \.element.id) { index, issue in
                            issueRow(index: index, issue: issue)
                            if index < report.issues.count - 1 {
                                LPDivider()
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(maxHeight: 300)
            }
        }
    }

    private func issueRow(index: Int, issue: ImportIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%02d", index + 1))
                .font(LPFont.mono(10))
                .foregroundStyle(LP.textTertiary)
                .frame(width: 20, alignment: .trailing)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Badge(text: kindLabel(issue.kind), color: kindColor(issue.kind))
                Text(issue.display)
                    .font(.system(size: 12))
                    .foregroundStyle(LP.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !issue.item.isEmpty, issue.item != issue.message {
                    Text(issue.item)
                        .font(LPFont.mono(10))
                        .foregroundStyle(LP.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kindLabel(issue.kind))：\(issue.display)")
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Button {
                LPClipboard.copy(plainText)
                copied = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .bold))
                    Text(copied ? "已复制" : "复制报告")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(LPGhostButtonStyle())
            .accessibilityLabel(copied ? "报告已复制" : "复制报告文本")
            Spacer()
            Button("完成") { onClose() }
                .buttonStyle(LPPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private func kindLabel(_ kind: ImportIssue.Kind) -> String {
        switch kind {
        case .unknownProtocol: return "协议"
        case .unknownGroupType: return "策略组"
        case .unsupportedSection: return "区块"
        case .unsupportedField: return "字段"
        case .skippedItem: return "跳过"
        case .parseError: return "解析"
        case .ruleError: return "规则"
        case .duplicateName: return "重名"
        }
    }

    private func kindColor(_ kind: ImportIssue.Kind) -> Color {
        switch kind {
        case .parseError: return LP.danger
        case .unknownProtocol, .unknownGroupType, .ruleError: return LP.amber
        case .unsupportedSection, .unsupportedField, .skippedItem, .duplicateName: return LP.textSecondary
        }
    }

    private var plainText: String {
        var lines = ["Leapin 导入报告", report.summary]
        if !report.notDialable.isEmpty {
            lines.append("- 暂不可拨号：\(report.notDialable.joined(separator: "、"))")
        }
        for issue in report.issues {
            lines.append("- [\(kindLabel(issue.kind))] \(issue.display)")
        }
        if report.issues.isEmpty { lines.append("- 没有发现问题") }
        return lines.joined(separator: "\n")
    }
}
