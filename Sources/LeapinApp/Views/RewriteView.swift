import SwiftUI
import LeapinCore
import LeapinRuntime

/// Editor for the profile's rewrite rules (one directive per line).
///
/// The rules are plain text so they can be copied from anywhere; the editor's job is
/// to make a bad line obvious before it silently does nothing.
struct RewriteView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var engine = LeapinEngine.shared

    @State private var editing: EditTarget?
    @State private var pendingDelete: Int?

    private struct EditTarget: Identifiable {
        let id = UUID()
        var index: Int?          // nil = new rule
        var line: String
    }

    private var lines: [String] { engine.profile.rewrites }

    /// Parsed view of every line, so the list can show what a rule actually does
    /// (and which ones will be ignored when the profile starts).
    private var parsed: [ParsedRule] {
        lines.map { line in
            switch RewriteEngine.parse(line) {
            case .success(let rule): return ParsedRule(line: line, rule: rule, issue: nil)
            case .failure(let issue): return ParsedRule(line: line, rule: nil, issue: issue.reason)
            }
        }
    }

    private struct ParsedRule: Identifiable {
        var id: String { line }
        var line: String
        var rule: RewriteRule?
        var issue: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            if engine.executionKernel == .mihomo {
                Text("Mihomo 模式下的流量由原始配置驱动，请求重写仍会生效，但分流以 Mihomo 为准。")
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textSecondary)
                    .padding(12)
            }

            HStack(alignment: .top, spacing: 22) {
                listPanel
                    .clipShape(RoundedRectangle(cornerRadius: LPGlass.panelRadius, style: .continuous))
                    .lpGlass(radius: LPGlass.panelRadius, fallbackFill: LP.panel, shadow: 0.06)
                sidePanel.frame(width: 292)
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("请求重写")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = EditTarget(index: nil, line: "")
                } label: {
                    Label("添加规则", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { target in
            RuleEditorSheet(
                initialLine: target.line,
                onSave: { line in
                    save(line, at: target.index)
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
        .lpConfirm("删除这条重写规则？",
                   message: pendingDelete.flatMap { $0 < lines.count ? lines[$0] : nil } ?? "",
                   isPresented: Binding(
                       get: { pendingDelete != nil },
                       set: { if !$0 { pendingDelete = nil } }
                   )) {
            deletePending()
        }
    }

    // MARK: - List

    private var listPanel: some View {
        VStack(spacing: 0) {
            HStack {
                SectionHeader(title: "重写规则",
                              subtitle: "\(lines.count) 条 · 按顺序匹配 URL",
                              icon: "arrow.triangle.2.circlepath")
                Spacer()
                if !lines.isEmpty {
                    Text("改动立即生效")
                        .font(Font.system(size: 10))
                        .foregroundStyle(LP.textTertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            LPDivider()

            if lines.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(parsed.enumerated()), id: \.offset) { index, item in
                            ruleRow(item, index: index)
                            if index < parsed.count - 1 {
                                LPDivider().padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func ruleRow(_ item: ParsedRule, index: Int) -> some View {
        Button {
            editing = EditTarget(index: index, line: item.line)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                phaseBadge(item)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.rule?.summary ?? "无法解析")
                        .font(LPFont.display(13, weight: .medium))
                        .foregroundStyle(item.issue == nil ? LP.text : LP.danger)
                    Text(item.line)
                        .font(LPFont.mono(10))
                        .foregroundStyle(LP.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let issue = item.issue {
                        Text(issue)
                            .font(Font.system(size: 10))
                            .foregroundStyle(LP.danger)
                    }
                }
                Spacer(minLength: 8)

                Button {
                    pendingDelete = index
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(LP.textTertiary)
                }
                .buttonStyle(.plain)
                .help("删除")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func phaseBadge(_ item: ParsedRule) -> some View {
        let isRequest = item.rule?.phase != .response
        return Text(isRequest ? "请求" : "响应")
            .font(Font.system(size: 10))
            .foregroundStyle(isRequest ? LP.accent : LP.violet)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill((isRequest ? LP.accent : LP.violet).opacity(0.14))
            )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(LP.textTertiary)
            Text("还没有重写规则")
                .font(LPFont.display(14, weight: .semibold))
                .foregroundStyle(LP.text)
            Text("可以改请求头、改响应正文、把某个接口替换成 Mock，或把域名重定向出去。")
                .font(Font.system(size: 12))
                .foregroundStyle(LP.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("添加第一条规则") {
                editing = EditTarget(index: nil, line: "")
            }
            .buttonStyle(LPPrimaryButtonStyle())
            .frame(width: 180)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: - Side panel

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "语法", subtitle: "一行一条，按顺序应用") {
                VStack(alignment: .leading, spacing: 8) {
                    syntaxLine("http-request", "匹配 URL 的正则")
                    syntaxLine("http-response", "响应阶段的规则")
                    LPDivider()
                    syntaxLine("header-add", "头名 值")
                    syntaxLine("header-del", "头名")
                    syntaxLine("header-replace", "头名 新值")
                    syntaxLine("body-replace", "被替换文本 替换为")
                    syntaxLine("redirect", "目标地址 [状态码]")
                    syntaxLine("mock", "状态码 内容类型 正文")
                }
            }

            Card(title: "说明") {
                VStack(alignment: .leading, spacing: 8) {
                    note("正则只匹配整条 URL，用 ^ 锁定开头更安全。")
                    note("Mock 与重定向在连接源站之前就返回，请求仍然会出现在抓包里。")
                    note("改模板里带空格的文本用双引号包起来，例如 \"a b\"。")
                    note("写错的行会被跳过并记录到日志，不会影响其他规则。")
                }
            }
        }
    }

    private func syntaxLine(_ keyword: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(keyword)
                .font(LPFont.mono(11, weight: .medium))
                .foregroundStyle(LP.accent)
            Text(detail)
                .font(Font.system(size: 10))
                .foregroundStyle(LP.textTertiary)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Font.system(size: 10))
            .foregroundStyle(LP.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Mutations

    private func save(_ line: String, at index: Int?) {
        var next = lines
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index, index < next.count {
            if trimmed.isEmpty { next.remove(at: index) } else { next[index] = trimmed }
        } else if !trimmed.isEmpty {
            next.append(trimmed)
        }
        let issues = engine.replaceRewrites(next)
        if let issue = issues.first {
            app.showToast("有一条规则被跳过：\(issue.reason)", kind: .warning)
        } else {
            app.showToast("重写规则已更新")
        }
    }

    private func deletePending() {
        guard let index = pendingDelete, index < lines.count else { return }
        var next = lines
        next.remove(at: index)
        _ = engine.replaceRewrites(next)
        pendingDelete = nil
        app.showToast("已删除")
    }
}

// MARK: - Editor sheet

private struct RuleEditorSheet: View {
    let initialLine: String
    var onSave: (String) -> Void
    var onCancel: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(initialLine: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.initialLine = initialLine
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: initialLine)
    }

    private var validation: (rule: RewriteRule?, error: String?) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return (nil, nil) }
        switch RewriteEngine.parse(line) {
        case .success(let rule): return (rule, nil)
        case .failure(let issue): return (nil, issue.reason)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: initialLine.isEmpty ? "添加重写规则" : "编辑重写规则",
                          icon: "arrow.triangle.2.circlepath")

            TextEditor(text: $text)
                .font(LPFont.mono(12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 76)
                .background(LP.panelRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(validation.error == nil ? LP.stroke : LP.danger.opacity(0.6), lineWidth: 1)
                )
                .focused($focused)
                .onAppear { focused = true }

            if let error = validation.error {
                Text(error).font(Font.system(size: 10)).foregroundStyle(LP.danger)
            } else if let rule = validation.rule {
                Text("\(rule.phase == .request ? "请求阶段" : "响应阶段") · \(rule.summary)")
                    .font(Font.system(size: 10))
                    .foregroundStyle(LP.mint)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("模板").font(Font.system(size: 10)).foregroundStyle(LP.textTertiary)
                FlowLayout(spacing: 6) {
                    ForEach(Self.templates, id: \.title) { template in
                        Button(template.title) { text = template.line }
                            .buttonStyle(.plain)
                            .font(Font.system(size: 10))
                            .foregroundStyle(LP.textSecondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(LP.panelRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(LP.stroke, lineWidth: 1))
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                Button("保存") { onSave(text) }
                    .buttonStyle(LPPrimaryButtonStyle())
                    .frame(width: 100)
                    .disabled(validation.rule == nil)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(LP.panel)
    }

    private static let templates: [(title: String, line: String)] = [
        ("添加请求头", #"http-request ^https?://api\.example\.com/ header-add X-Debug 1"#),
        ("改响应头", #"http-response ^https?://api\.example\.com/ header-replace Cache-Control no-store"#),
        ("替换正文", #"http-response ^https?://api\.example\.com/user body-replace "\"vip\":false" "\"vip\":true""#),
        ("Mock 接口", #"http-request ^https?://api\.example\.com/mock mock 200 application/json {"ok":true}"#),
        ("重定向", #"http-request ^https?://old\.example\.com/ redirect https://new.example.com 302"#),
    ]
}

/// Minimal wrapping layout for the template chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
