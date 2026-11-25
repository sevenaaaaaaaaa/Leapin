import SwiftUI
import LeapinControl

/// 首页：这台手机的网络（v6 · Live Instrument）。
///
/// 四个块：墨色 hero（可拖的路 + 可回看的时间河 + 四个事实 + 一个主操作）、
/// 可编排的卡片、就地草稿行、回执条。三问的顺序不变：
/// 引擎开没开、系统用没用上、Mac 在不在线。
struct DashboardView: View {
    @Environment(ConsoleStore.self) private var store
    private var local: LocalProxyEngine { .shared }

    @State private var showSettings = false
    @State private var showGuide = false
    @State private var reloadSummary: String?
    @State private var isReloading = false

    // v6
    @State private var deck = LPDeckStore(defaults: [
        LPCardSpec(id: "engine", span: .s),
        LPCardSpec(id: "mac", span: .s),
        LPCardSpec(id: "recent", span: .l),
        LPCardSpec(id: "check", span: .s),
        LPCardSpec(id: "rules", span: .s),
    ])
    @State private var composing = false
    private var feed: LPRiverFeed { .shared }
    @State private var frozen: Int?
    @State private var unfreezeTask: Task<Void, Never>?
    @State private var rateIn: Double = 0
    @State private var rateOut: Double = 0
    @State private var lastIn = 0
    @State private var lastOut = 0
    @State private var receipt: ExitReceipt?
    @State private var draft = ""
    @State private var proposal: DraftProposal?
    @State private var draftNotice: String?
    @State private var pendingExit: String?
    @AppStorage("lp.agent.draftBar") private var draftBarEnabled = true
    @AppStorage("lp.agent.confirmExit") private var confirmExitBeforeSwitch = false
    @AppStorage("lp.river.holdSeconds") private var riverHoldSeconds = 3

    @Environment(\.horizontalSizeClass) private var sizeClass
    private var columns: Int { sizeClass == .compact ? 2 : 4 }

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LEAPIN_MOBILE_GUIDE"] == "1" {
            _showGuide = State(initialValue: true)
        }
        // 截图与设计评审用：直接进入编排态，不用真的长按。
        if ProcessInfo.processInfo.environment["LEAPIN_MOBILE_COMPOSE"] == "1" {
            _composing = State(initialValue: true)
        }
        if ProcessInfo.processInfo.environment["LEAPIN_MOBILE_SETTINGS"] == "1" {
            _showSettings = State(initialValue: true)
        }
        #endif
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    hero
                    if let receipt { receiptBar(receipt) }
                    if let proposal { proposalCard(proposal) }
                    deckGrid
                    footerNote
                }
                .padding(.horizontal, LP.gutter)
                .padding(.top, 8)
                .padding(.bottom, 160)
            }
            .background(LP.canvas)
            .refreshable { await store.refresh() }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showGuide) { LocalProxyGuide() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if draftBarEnabled {
                    LPAgentDraftBar(
                        text: $draft,
                        placeholder: draftNotice ?? "告诉我要改什么",
                        busy: false,
                        suggestions: ["启动本机引擎", "自检一次", "配对 Mac"]
                    ) { handleDraft($0) }
                }
            }
            .confirmationDialog("切换出口？", isPresented: Binding(
                get: { pendingExit != nil },
                set: { if !$0 { pendingExit = nil } }
            ), titleVisibility: .visible) {
                if let id = pendingExit {
                    Button("切到 \(id)") {
                        if let group { performExit(id, group: group) }
                        pendingExit = nil
                    }
                }
                Button("取消", role: .cancel) { pendingExit = nil }
            } message: {
                Text("会影响所有走这条策略的连接。")
            }
        }
        .task { feed.start() }
    }

    // MARK: - 页头

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("这台手机的网络")
                    .font(LPFont.title)
                    .foregroundStyle(LP.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(statusLine)
                    .font(LPFont.body)
                    .foregroundStyle(LP.textSecondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { composing.toggle() }
                    LPHaptic.soft()
                } label: {
                    Text(composing ? "完成" : "编排")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(composing ? LP.accent : LP.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(composing ? LP.accentSoft : LP.panel))
                        .overlay(Capsule().strokeBorder(composing ? LP.accent.opacity(0.4) : LP.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(composing ? "完成编排" : "编排卡片")

                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LP.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(LP.panel))
                        .overlay(Circle().strokeBorder(LP.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置")
            }
        }
    }

    private var statusLine: String {
        guard local.isRunning else { return "本机引擎未启动" }
        return "引擎运行中 · 127.0.0.1:\(local.port) · 全部直连"
    }

    // MARK: - 墨色 hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("现在")
                    .font(LPFont.label)
                    .tracking(0.8)
                    .foregroundStyle(LP.onInkSecondary)
                Circle()
                    .fill(local.isRunning ? LP.accent : LP.onInkSecondary.opacity(0.5))
                    .frame(width: 5, height: 5)
                Spacer(minLength: 0)
                Text(frozenReadout)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(LP.onInkSecondary)
            }

            LPRouteScrubber(
                stops: exits,
                selectedID: selectedExitID,
                judge: judgeName,
                enabled: store.isConnected && exits.count > 1,
                onCommit: commitExit
            )

            LPRiver(samples: feed.samples, frozenIndex: frozen, enabled: local.isRunning,
                    onInk: true, height: 46) { index in
                guard let index else { return }   // 松手不清空：保持 3 秒再回实时
                frozen = index
                unfreezeTask?.cancel()
                unfreezeTask = Task {
                    try? await Task.sleep(for: .seconds(Double(max(1, riverHoldSeconds))))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.2)) { frozen = nil }
                }
            }

            HStack(alignment: .top, spacing: 10) {
                LPFact(label: "连接", value: String(local.activeConnections))
                LPFact(label: "下行", value: LPFormat.bytes(Int64(rateIn)) + "/s")
                LPFact(label: "上行", value: LPFormat.bytes(Int64(rateOut)) + "/s")
                LPFact(label: "系统代理", value: usageLabel, mono: false)
            }

            Button {
                if local.isRunning {
                    showGuide = true
                } else {
                    local.start()
                    LPHaptic.success()
                }
            } label: {
                Text(local.isRunning ? "把 Wi-Fi 代理指过来" : "启动本机引擎")
            }
            .buttonStyle(OnInkButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LP.ink, in: RoundedRectangle(cornerRadius: LP.radius, style: .continuous))
    }

    private var frozenReadout: String {
        guard let frozen, feed.samples.indices.contains(frozen) else {
            if !local.isRunning { return "已停止" }
            return feed.samples.allSatisfy({ $0.down == 0 && $0.up == 0 }) ? "还没有波形" : "最近 60 秒"
        }
        let ago = max(0, feed.samples.count - 1 - frozen)
        let sample = feed.samples[frozen]
        return "−\(ago)s · 回看中 · ↓\(Int(sample.down * 100))% ↑\(Int(sample.up * 100))%"
    }

    // MARK: - 回执（拖动结果可撤销）

    private struct ExitReceipt: Identifiable {
        let id = UUID()
        var from: String
        var to: String
    }

    private func receiptBar(_ item: ExitReceipt) -> some View {
        HStack(spacing: 8) {
            Circle().fill(LP.accent).frame(width: 5, height: 5)
            Text("已切到 \(item.to)")
                .font(.system(size: 12))
                .foregroundStyle(LP.text)
            Spacer(minLength: 6)
            Button("撤销") {
                Task {
                    _ = await store.select(group: judgeName, outbound: item.from)
                    receipt = nil
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(LP.accent)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(LP.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(LP.stroke, lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
        .task(id: item.id) {
            try? await Task.sleep(for: .seconds(6))
            withAnimation(.easeOut(duration: 0.2)) { receipt = nil }
        }
    }

    // MARK: - 草稿结果

    private struct DraftProposal: Identifiable {
        var id: String { title }
        var title: String
        var detail: String
        var applies: Bool
        var apply: () -> Void
    }

    private func proposalCard(_ item: DraftProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LP.accent)
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LP.text)
                Spacer(minLength: 4)
                Button {
                    withAnimation { proposal = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LP.textTertiary)
                }
                .buttonStyle(.plain)
            }
            Text(item.detail)
                .font(.system(size: 12))
                .foregroundStyle(LP.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if item.applies {
                HStack(spacing: 8) {
                    Button("应用") {
                        item.apply()
                        withAnimation { proposal = nil }
                        LPHaptic.success()
                    }
                    .buttonStyle(LPButtonStyle(fullWidth: false))
                    Button("放弃") { withAnimation { proposal = nil } }
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textSecondary)
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(LP.panel, in: RoundedRectangle(cornerRadius: LP.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LP.radius, style: .continuous)
                .strokeBorder(LP.accent.opacity(0.28), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - 卡片编排

    private var deckGrid: some View {
        VStack(spacing: 10) {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(Array(deckRows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(row) { spec in
                            LPCardTile(id: spec.id, store: deck, editing: composing) {
                                cardBody(spec.id)
                            }
                            .gridCellColumns(spec.span.columns(in: columns))
                        }
                        let used = row.reduce(0) { $0 + $1.span.columns(in: columns) }
                        if used < columns {
                            Color.clear.gridCellColumns(columns - used)
                        }
                    }
                }
            }
            if composing {
                Button {
                    deck.reset([
                        LPCardSpec(id: "engine", span: .s),
                        LPCardSpec(id: "mac", span: .s),
                        LPCardSpec(id: "recent", span: .l),
                        LPCardSpec(id: "check", span: .s),
                        LPCardSpec(id: "rules", span: .s),
                    ])
                } label: {
                    Text("恢复默认布局")
                        .font(.system(size: 11))
                        .foregroundStyle(LP.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeOut(duration: 0.2), value: composing)
    }

    private var visibleSpecs: [LPCardSpec] {
        deck.specs.filter { composing || !$0.hidden }
    }

    /// 贪心装行：一行装不下就换行。4 列的宽屏与 2 列的手机用同一套算法。
    private var deckRows: [[LPCardSpec]] {
        var rows: [[LPCardSpec]] = []
        var current: [LPCardSpec] = []
        var used = 0
        for spec in visibleSpecs {
            let span = spec.span.columns(in: columns)
            if used + span > columns, !current.isEmpty {
                rows.append(current)
                current = []
                used = 0
            }
            current.append(spec)
            used += span
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    @ViewBuilder
    private func cardBody(_ id: String) -> some View {
        switch id {
        case "engine": engineCard
        case "mac": macCard
        case "recent": recentCard
        case "check": checkCard
        case "rules": rulesCard
        default: EmptyView()
        }
    }

    private var cardHeader: some View {
        Rectangle().fill(.clear).frame(height: 0)
    }

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本机引擎")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LP.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(local.isRunning ? "监听中" : "已停止")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LP.text)
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(
                    get: { local.isRunning },
                    set: { on in
                        if on { local.start() } else { local.stop() }
                        LPHaptic.soft()
                    }
                ))
                .labelsHidden()
                .tint(LP.accent)
            }
            Text(local.isRunning ? "127.0.0.1:\(String(local.port))" : "打开后接管本机流量")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(LP.textTertiary)
        }
    }

    private var macCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mac")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LP.textTertiary)
            if let endpoint = store.endpoint {
                Text(stateTitle(store.status?.engineState ?? "unknown"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LP.text)
                Text(endpoint.displayAddress)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(LP.textTertiary)
                    .lineLimit(1)
            } else {
                Button("未连接 · 配对") { store.pairingSheetShown = true }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LP.accent)
                    .buttonStyle(.plain)
                Text("不配对也能用本机引擎")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LP.textTertiary)
            }
        }
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近请求")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LP.textTertiary)
                Spacer()
                Text(local.isRunning ? "本机" : (store.endpoint == nil ? "无数据" : "Mac"))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(LP.textTertiary)
            }
            let rows = Array((local.isRunning ? local.localConnections : store.connections).prefix(3))
            if rows.isEmpty {
                Text("还没有请求。打开一个网页，这里会出现第一条。")
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 8) {
                            Text(row.host)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(LP.text)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(row.policy)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(LP.textTertiary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 5)
                        if index < rows.count - 1 {
                            Rectangle().fill(LP.separator).frame(height: 0.5)
                        }
                    }
                }
            }
        }
    }

    private var checkCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("体检")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LP.textTertiary)
            Button {
                Task { await local.selfCheck() }
            } label: {
                HStack(spacing: 4) {
                    Text(local.isChecking ? "检查中…" : "自检")
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(local.isRunning ? LP.accent : LP.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!local.isRunning || local.isChecking)
            Text(local.lastCheck ?? "经本机代理取一次 example.com")
                .font(.system(size: 10.5))
                .foregroundStyle(LP.textTertiary)
                .lineLimit(2)
        }
    }


    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("规则")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LP.textTertiary)
            Text(store.status.map { String($0.ruleCount) } ?? "—")
                .font(LPFont.number)
                .foregroundStyle(LP.text)
            Text(store.status == nil ? "配对后显示 Mac 的规则" : "来自 Mac")
                .font(.system(size: 10.5))
                .foregroundStyle(LP.textTertiary)
                .lineLimit(2)
        }
    }

    // MARK: - 出口

    private var group: ControlPolicyGroup? {
        store.policies.first(where: { $0.members.count > 1 })
            ?? store.policies.first
    }

    private var judgeName: String {
        guard let group else { return "—" }
        return group.name
    }

    private var exits: [LPRouteScrubber.Stop] {
        guard let group, !group.members.isEmpty else {
            return [.init(id: "direct", label: "直连", detail: "本机")]
        }
        return group.members.map { member in
            LPRouteScrubber.Stop(id: member, label: member,
                                 detail: member == group.effective ? "生效中" : group.type)
        }
    }

    private var selectedExitID: String {
        guard let group else { return "direct" }
        return group.selected.isEmpty ? group.effective : group.selected
    }

    private func commitExit(_ id: String) {
        guard let group, id != selectedExitID else { return }
        if confirmExitBeforeSwitch {
            pendingExit = id
            return
        }
        performExit(id, group: group)
    }

    private func performExit(_ id: String, group: ControlPolicyGroup) {
        let previous = selectedExitID
        Task {
            let ok = await store.select(group: group.name, outbound: id)
            if ok {
                withAnimation { receipt = ExitReceipt(from: previous, to: id) }
            } else {
                draftNotice = store.lastError ?? "切换失败"
            }
        }
    }

    // MARK: - 采样

    // MARK: - 草稿解析

    private func handleDraft(_ text: String) {
        let value = text.lowercased()
        draftNotice = nil
        if value.contains("停") || value.contains("关闭") || value.contains("直连") {
            if local.isRunning {
                proposal = DraftProposal(
                    title: "停止本机引擎",
                    detail: "监听 127.0.0.1:\(local.port) 会关闭，已建立的连接会断开。",
                    applies: true
                ) { local.stop() }
            } else {
                draftNotice = "引擎已经停了"
            }
            return
        }
        if value.contains("启动") || value.contains("开始") || value.contains("打开") || value.contains("监听") {
            if !local.isRunning {
                proposal = DraftProposal(
                    title: "启动本机引擎",
                    detail: "在本机 51003 端口监听；系统 Wi-Fi 代理仍需你手动指过来。",
                    applies: true
                ) { local.start() }
            } else {
                draftNotice = "引擎已经在跑"
            }
            return
        }
        if value.contains("自检") || value.contains("测") || value.contains("检查") {
            proposal = DraftProposal(
                title: "经本机代理自检",
                detail: local.isRunning ? "取一次 example.com，确认 CONNECT 与转发真的通了。" : "先启动引擎才能自检。",
                applies: local.isRunning
            ) { Task { await local.selfCheck() } }
            return
        }
        if value.contains("配对") || value.contains("mac") {
            proposal = DraftProposal(
                title: "配对 Mac",
                detail: "扫码或输入 Mac 的地址与令牌；配对后这里会显示 Mac 的规则与出口。",
                applies: true
            ) { store.pairingSheetShown = true }
            return
        }
        draftNotice = "可以试试：启动 / 停止 / 自检 / 配对 Mac"
        LPHaptic.warning()
    }

    // MARK: - 页脚

    private var footerNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 10))
            Text(store.lastUpdated.map { "Mac 更新于 \(LPFormat.timeAgo($0))" } ?? "尚未连过 Mac")
                .font(.system(size: 11))
        }
        .foregroundStyle(LP.textTertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }

    // MARK: - 文案

    private var usageLabel: String {
        guard local.isRunning else { return "未设置" }
        guard let check = local.lastCheck else { return "未验证" }
        return check.contains("收到 HTTP") ? "已验证" : "未通过"
    }

    private func stateTitle(_ state: String) -> String {
        switch state.lowercased() {
        case "running": return "正在保护"
        case "starting": return "正在启动"
        case "stopping": return "正在停止"
        case "failed": return "启动失败"
        case "stopped": return "已停止"
        default: return "未知状态"
        }
    }
}

/// ink 底上的主按钮：纸色底、墨色字。一屏只有一个。
struct OnInkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LPFont.body.weight(.semibold))
            .foregroundStyle(LP.ink)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous)
                    .fill(LP.onInk.opacity(configuration.isPressed ? 0.82 : 1))
            )
    }
}
