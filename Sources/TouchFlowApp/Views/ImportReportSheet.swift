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
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill((blocking ? TF.danger : report.isClean ? TF.mint : TF.amber).opacity(0.16))
                Image(systemName: blocking ? "exclamationmark.triangle.fill" : report.isClean ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(blocking ? TF.danger : report.isClean ? TF.mint : TF.amber)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(blocking ? "导入未完成" : report.isClean ? "导入成功" : "导入完成，有需要留意的地方")
                    .font(TFFont.display(15, weight: .bold))
                    .foregroundStyle(TF.text)
                Text(report.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(TF.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var counters: some View {
        HStack(spacing: 22) {
            counter("格式", report.format)
            counter("出站", "\(report.outboundCount)")
            counter("策略组", "\(report.groupCount)")
            counter("规则", "\(report.ruleCount)")
            if report.skippedOutbounds > 0 {
                counter("跳过", "\(report.skippedOutbounds)", tint: TF.amber)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 11)
    }

    private func counter(_ label: String, _ value: String, tint: Color = TF.text) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(TFFont.num(12, weight: .semibold)).foregroundStyle(tint)
            Text(label).font(.system(size: 9)).foregroundStyle(TF.textTertiary)
        }
    }

    private var issueList: some View {
        Group {
            if report.issues.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle").font(.system(size: 11)).foregroundStyle(TF.mint)
                    Text("所有字段都已识别，没有跳过任何内容。")
                        .font(.system(size: 11))
                        .foregroundStyle(TF.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(report.issues) { issue in
                            HStack(alignment: .top, spacing: 9) {
                                Text(kindLabel(issue.kind))
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(kindColor(issue.kind))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(kindColor(issue.kind).opacity(0.14), in: Capsule())
                                    .fixedSize()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.display)
                                        .font(.system(size: 11))
                                        .foregroundStyle(TF.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if !issue.item.isEmpty, issue.item != issue.message {
                                        Text("› \(issue.item)")
                                            .font(TFFont.mono(9.5))
                                            .foregroundStyle(TF.textTertiary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            TFDivider().opacity(0.5)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(maxHeight: 300)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Button {
                TFClipboard.copy(plainText)
                copied = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9, weight: .bold))
                    Text(copied ? "已复制" : "复制报告").font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(TFGhostButtonStyle())
            Spacer()
            Button("完成") { onClose() }
                .buttonStyle(TFPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 13)
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
