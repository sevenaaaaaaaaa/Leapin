import SwiftUI
import AppKit
import TouchFlowCore
import TouchFlowPolicy

/// 导入报告：把解析器实际看懂/跳过的内容如实列出来，而不是假装全部成功。
@MainActor
struct ImportReportSheet: View {
    let report: ImportReport
    var onClose: () -> Void

    @State private var copied = false

    private var blocking: Bool { report.issues.contains { $0.kind.isBlocking } }
    private var statusColor: Color { blocking ? TF.danger : report.isClean ? TF.mint : TF.amber }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            TFDivider()
            counters
            TFDivider()
            issueList
            TFDivider()
            footer
        }
        .frame(width: 580)
        .background(TF.panelSolid)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: blocking ? "exclamationmark.triangle" : report.isClean ? "checkmark.seal" : "exclamationmark.circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(statusColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 5) {
                TFEyebrow(blocking ? "IMPORT REPORT · BLOCKED" : "IMPORT REPORT", tint: TF.textTertiary)
                Text(blocking ? "导入未完成" : report.isClean ? "导入成功" : "导入完成，有需要留意的地方")
                    .font(TFFont.display(15, weight: .semibold))
                    .foregroundStyle(TF.text)
                Text(report.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(TF.textSecondary)
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
                counter("跳过", "\(report.skippedOutbounds)", tint: TF.amber)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func counter(_ label: String, _ value: String, tint: Color = TF.text) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            TFEyebrow(label, tint: TF.textTertiary)
            Text(value)
                .font(TFFont.num(14, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(minWidth: 54, alignment: .leading)
    }

    private var counterDivider: some View {
        Rectangle()
            .fill(TF.stroke)
            .frame(width: 1, height: 28)
            .padding(.horizontal, 14)
    }

    private var issueList: some View {
        Group {
            if report.issues.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.mint)
                    Text("所有字段都已识别，没有跳过任何内容。")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.textSecondary)
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
                                TFDivider()
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
                .font(TFFont.mono(10))
                .foregroundStyle(TF.textTertiary)
                .frame(width: 20, alignment: .trailing)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Badge(text: kindLabel(issue.kind), color: kindColor(issue.kind))
                Text(issue.display)
                    .font(.system(size: 12))
                    .foregroundStyle(TF.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !issue.item.isEmpty, issue.item != issue.message {
                    Text(issue.item)
                        .font(TFFont.mono(10))
                        .foregroundStyle(TF.textTertiary)
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
                TFClipboard.copy(plainText)
                copied = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .bold))
                    Text(copied ? "已复制" : "复制报告")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(TFGhostButtonStyle())
            .accessibilityLabel(copied ? "报告已复制" : "复制报告文本")
            Spacer()
            Button("完成") { onClose() }
                .buttonStyle(TFPrimaryButtonStyle())
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
        case .parseError: return TF.danger
        case .unknownProtocol, .unknownGroupType, .ruleError: return TF.amber
        case .unsupportedSection, .unsupportedField, .skippedItem, .duplicateName: return TF.textSecondary
        }
    }

    private var plainText: String {
        var lines = ["TouchFlow 导入报告", report.summary]
        for issue in report.issues {
            lines.append("- [\(kindLabel(issue.kind))] \(issue.display)")
        }
        if report.issues.isEmpty { lines.append("- 没有发现问题") }
        return lines.joined(separator: "\n")
    }
}
