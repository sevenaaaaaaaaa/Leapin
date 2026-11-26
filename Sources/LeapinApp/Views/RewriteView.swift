import SwiftUI
import LeapinCore
import LeapinRuntime

/// 「改成什么」：重写 / Mock / 脚本 / 去广告 四个 tab。
///
/// M2 的分工（docs/tasks/product-v4.md T-09）：页头只切 tab；四类的列表与落地都在
/// RewriteDeck 里，四类共用一条生效路径。去广告 tab 直接复用 AdBlockView——视图与
/// 仪表条都不另写一份，只是把列表数据换成 Deck 的行。
///
/// tab 住在页头里（`lpHeaderTabs`）；这一页唯一的主按钮放在列表自己的标题行上，
/// 不再单独占一条工具条。
@MainActor
struct RewriteView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var engine = LeapinEngine.shared

    /// 四类的列表与唯一 apply 入口。Deck 不存状态，所以每次取值都指向同一个引擎。
    private var deck: RewriteDeck { RewriteDeck() }

    @State private var tab: RewriteDeck.Kind = .rewrite
    @State private var editing: EditTarget?
    @State private var pendingDelete: RewriteDeck.Row?

    private static let owner = "whatChanged"
    private static let tabs: [LPTab] = RewriteDeck.Kind.allCases.map { LPTab(id: $0.rawValue, title: $0.title) }

    private struct EditTarget: Identifiable {
        let id = UUID()
        var kind: RewriteDeck.Kind
        var index: Int?          // nil = 新规则
        var line: String
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lpHeaderTabs(owner: Self.owner, items: Self.tabs, selected: tab.rawValue) { id in
            guard let kind = RewriteDeck.Kind(rawValue: id) else { return }
            LPMotion.run(LPMotion.press) { tab = kind }
        }
        .onAppear { consumePendingLine() }
        .onChange(of: app.pendingRewriteLine) { _, _ in consumePendingLine() }
        .sheet(item: $editing) { target in
            RuleEditorSheet(
                kind: target.kind,
                initialLine: target.line,
                onSave: { line in
                    switch target.kind {
                    case .mock: commitMock(line, at: target.index)
                    default: commitRewrite(line, at: target.index)
                    }
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
        .lpConfirm("删除这条\(tab == .mock ? "Mock" : "重写")规则？",
                   message: pendingDelete?.detail ?? "",
                   isPresented: Binding(
                       get: { pendingDelete != nil },
                       set: { if !$0 { pendingDelete = nil } }
                   )) {
            deletePending()
        }
    }

    // MARK: - Tabs

    @ViewBuilder private var content: some View {
        switch tab {
        case .rewrite: listTab(for: .rewrite)
        case .mock: listTab(for: .mock)
        case .script: scriptTab
        case .adblock:
            // 视图整体复用；列表数据与落地都在 Deck，AdBlockView 只渲染。
            AdBlockView(embedded: true, deck: RewriteDeck())
        }
    }

    // MARK: - 重写 / Mock

    private func listTab(for kind: RewriteDeck.Kind) -> some View {
        VStack(spacing: 0) {
            if engine.executionKernel == .mihomo {
                Text("Mihomo 模式下的流量由原始配置驱动，请求重写仍会生效，但分流以 Mihomo 为准。")
                    .font(.system(size: 13))
                    .foregroundStyle(LP.textSecondary)
                    .padding(.horizontal, LPSpace.inset)
                    .padding(.top, 12)
            }

            HStack(alignment: .top, spacing: 22) {
                listPanel(for: kind)
                    .clipShape(RoundedRectangle(cornerRadius: LPRadius.panel, style: .continuous))
                    .lpSheet()
                sidePanel(for: kind).frame(width: 292)
            }
            .padding(.horizontal, LPSpace.inset)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
    }

    private func listPanel(for kind: RewriteDeck.Kind) -> some View {
        let rows = deck.rows(for: kind)
        return VStack(spacing: 0) {
            HStack {
                SectionHeader(title: kind == .mock ? "Mock 规则" : "重写规则",
                              subtitle: "\(rows.count) 条 · 按顺序匹配 URL",
                              icon: kind.icon)
                Spacer()
                if !rows.isEmpty {
                    Text("改动立即生效")
                        .font(Font.system(size: 11))
                        .foregroundStyle(LP.textTertiary)
                }
                // 这一页唯一的主按钮：放在列表自己的标题行上，不另占一条工具条。
                Button {
                    addRule(for: kind)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        Text(kind == .mock ? "新建 Mock" : "新建规则").font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(LPPrimaryButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            LPDivider()

            if rows.isEmpty {
                emptyState(for: kind)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                            ruleRow(row)
                            if offset < rows.count - 1 {
                                LPDivider().padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func ruleRow(_ row: RewriteDeck.Row) -> some View {
        Button {
            editing = EditTarget(kind: row.kind, index: row.index, line: row.detail)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if let badge = row.badge {
                    phaseBadge(badge)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(LPFont.display(13, weight: .medium))
                        .foregroundStyle(row.issue == nil ? LP.text : LP.danger)
                    Text(row.detail)
                        .font(LPFont.mono(11))
                        .foregroundStyle(LP.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let issue = row.issue {
                        Text(issue)
                            .font(Font.system(size: 11))
                            .foregroundStyle(LP.danger)
                    }
                }
                Spacer(minLength: 8)

                Button {
                    pendingDelete = row
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

    private func phaseBadge(_ text: String) -> some View {
        let isRequest = text == "请求"
        return Text(text)
            .font(Font.system(size: 11))
            .foregroundStyle(isRequest ? LP.accent : LP.violet)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill((isRequest ? LP.accent : LP.violet).opacity(0.14))
            )
    }

    /// 空列表不是一块居中的空白：标题、一句说明，然后是几行能直接用的例子。
    /// 点一行就带着它打开编辑器——第一次用的人不必先背语法。
    private func emptyState(for kind: RewriteDeck.Kind) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(kind.emptyTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LP.text)
                Text(kind.emptyDetail)
                    .font(.system(size: 13))
                    .foregroundStyle(LP.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)

            ForEach(Array(kind.samples.enumerated()), id: \.offset) { _, sample in
                SampleRow(title: sample.title, line: sample.line) {
                    editing = EditTarget(kind: kind, index: nil, line: sample.line)
                }
                .overlay(alignment: .top) { LPDivider() }
            }

            if kind == .rewrite || kind == .mock {
                Button(kind == .mock ? "从空白开始写一条 Mock" : "从空白开始写一条规则") {
                    addRule(for: kind)
                }
                .buttonStyle(LPGhostButtonStyle())
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .overlay(alignment: .top) { LPDivider() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Side panel

    @ViewBuilder private func sidePanel(for kind: RewriteDeck.Kind) -> some View {
        if kind == .mock {
            VStack(alignment: .leading, spacing: 14) {
                Card(title: "Mock 怎么用", subtitle: "命中就返回，不再连源站") {
                    VStack(alignment: .leading, spacing: 8) {
                        syntaxLine("mock", "状态码 内容类型 正文")
                        syntaxLine("redirect", "目标地址 [状态码]")
                    }
                }

                Card(title: "说明") {
                    VStack(alignment: .leading, spacing: 8) {
                        note("Mock 在连接源站之前就返回，请求仍然会出现在抓包里。")
                        note("从抓包里改成 Mock 会把这一行预填进编辑器，点保存才生效。")
                        note("写错的行会被跳过并记录到日志，不会影响其他规则。")
                    }
                }
            }
        } else {
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
    }

    private func syntaxLine(_ keyword: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(keyword)
                .font(LPFont.mono(11, weight: .medium))
                .foregroundStyle(LP.accent)
            Text(detail)
                .font(Font.system(size: 11))
                .foregroundStyle(LP.textTertiary)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Font.system(size: 11))
            .foregroundStyle(LP.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 脚本

    /// 脚本 tab 只读：列名字与阶段，只给启停开关。编辑器 PRD 明确后补，这里不做。
    private var scriptTab: some View {
        let rows = deck.rows(for: .script)
        return VStack(spacing: 0) {
            HStack {
                SectionHeader(title: "脚本",
                              subtitle: "\(rows.count) 个 · 按阶段挂到请求或响应上",
                              icon: RewriteDeck.Kind.script.icon)
                Spacer()
                Text("只读 · 只能启停")
                    .font(Font.system(size: 11))
                    .foregroundStyle(LP.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            LPDivider()

            if rows.isEmpty {
                emptyState(for: .script)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                            scriptRow(row)
                            if offset < rows.count - 1 {
                                LPDivider().padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: LPRadius.panel, style: .continuous))
        .lpSheet()
        .padding(.horizontal, LPSpace.inset)
        .padding(.top, 14)
        .padding(.bottom, 20)
    }

    private func scriptRow(_ row: RewriteDeck.Row) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "curlybraces")
                .font(.system(size: 11))
                .foregroundStyle(LP.textTertiary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(LPFont.mono(12, weight: .medium))
                    .foregroundStyle(LP.text)
                Text(row.detail)
                    .font(Font.system(size: 11))
                    .foregroundStyle(LP.textTertiary)
            }
            Spacer(minLength: 8)

            LPSwitch(isOn: Binding(
                get: { row.enabled },
                set: { commitScript(row, enabled: $0) }
            ), tint: LP.accent, width: 32)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 落地（四类各一处，全部走 Deck 的 applyRewrite）

    private func commitRewrite(_ line: String, at index: Int?) {
        report(deck.applyRewrite(.rewrite(line: line, at: index)))
    }

    private func commitMock(_ line: String, at index: Int?) {
        report(deck.applyRewrite(.mock(line: line, at: index)))
    }

    private func commitScript(_ row: RewriteDeck.Row, enabled: Bool) {
        // 脚本行一定带位置；没有位置的 Row 不是脚本行，宁可不写也不猜。
        guard let index = row.index else { return }
        report(deck.applyRewrite(.script(index: index, enabled: enabled)))
    }

    /// 四类共用同一段提示处理：成功与被跳过的原因在四个 tab 里读起来一样。
    private func report(_ outcome: RewriteDeck.Outcome) {
        app.showToast(outcome.message,
                      kind: outcome.kind,
                      actionTitle: outcome.undo == nil ? nil : "撤销",
                      action: outcome.undo)
    }

    private func addRule(for kind: RewriteDeck.Kind) {
        switch kind {
        case .mock:
            // 新 Mock 先给一条能直接改的骨架，省掉用户背语法。
            editing = EditTarget(kind: .mock,
                                 index: nil,
                                 line: RewriteTemplate.mockLine(url: "https://api.example.com/mock"))
        default:
            editing = EditTarget(kind: .rewrite, index: nil, line: "")
        }
    }

    /// 抓包行会带上一条 Mock 规则跳进来；落到 Mock tab 并打开编辑器。
    private func consumePendingLine() {
        guard let line = app.pendingRewriteLine else { return }
        app.pendingRewriteLine = nil
        tab = .mock
        editing = EditTarget(kind: .mock, index: nil, line: line)
    }

    private func deletePending() {
        guard let row = pendingDelete else { return }
        pendingDelete = nil
        switch row.kind {
        case .rewrite: commitRewrite("", at: row.index)
        case .mock: commitMock("", at: row.index)
        case .script, .adblock:
            // 脚本只读，来源用它自己行上的减号；这两类不该走到删除确认框。
            return
        }
    }
}

// MARK: - 示例行

/// 空态里的一个例子：名字、原始规则行，点一下带着它进编辑器。
private struct SampleRow: View {
    let title: String
    let line: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LP.text)
                    .frame(width: 76, alignment: .leading)
                Text(line)
                    .font(LPFont.mono(11))
                    .foregroundStyle(hovering ? LP.textSecondary : LP.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("用这个示例")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LP.accent)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(hovering ? LP.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .lpAnimation(LPMotion.quick, value: hovering)
        .accessibilityLabel("用示例「\(title)」新建规则")
    }
}

// MARK: - Editor sheet

private struct RuleEditorSheet: View {
    let kind: RewriteDeck.Kind
    let initialLine: String
    var onSave: (String) -> Void
    var onCancel: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(kind: RewriteDeck.Kind,
         initialLine: String,
         onSave: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.kind = kind
        self.initialLine = initialLine
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: initialLine)
    }

    private var headerTitle: String {
        let name = kind == .mock ? "Mock" : "重写规则"
        return initialLine.isEmpty ? "添加\(name)" : "编辑\(name)"
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
            SectionHeader(title: headerTitle,
                          icon: kind.icon)

            TextEditor(text: $text)
                .font(LPFont.mono(13))
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
                Text(error).font(Font.system(size: 11)).foregroundStyle(LP.danger)
            } else if let rule = validation.rule {
                Text("\(rule.phase == .request ? "请求阶段" : "响应阶段") · \(rule.summary)")
                    .font(Font.system(size: 11))
                    .foregroundStyle(LP.mint)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("模板").font(Font.system(size: 11)).foregroundStyle(LP.textTertiary)
                FlowLayout(spacing: 6) {
                    ForEach(kind.samples, id: \.title) { template in
                        Button(template.title) { text = template.line }
                            .buttonStyle(.plain)
                            .font(Font.system(size: 11))
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
        .background(LP.sheet)
    }
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
