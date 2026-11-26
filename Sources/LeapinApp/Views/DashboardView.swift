import SwiftUI
import Combine
import AppKit
import LeapinCore
import LeapinRuntime

/// A deliberately low-frequency snapshot of the engine: state, active profile and
/// configuration flags only. It never subscribes to flows or stats, so the
/// overview does not re-render on every connection.
///
/// 「走哪」首屏那几个事实**不在这里算**：它们来自 `ResidentStatusStore`（和菜单栏
/// 面板、实时浮窗同一个对象），速率差分也只发生在那里一次。这里多出来的两个数
/// （规则数 / 去广告规则数）不是采样，而是「当前配置有几条」这种随配置变化、
/// 频率很低的事实，所以跟着 `$profile` / `$state` 一起刷新，仍然不订阅 `$stats`。
@MainActor
final class OverviewModel: ObservableObject {
    @Published var state: EngineState
    @Published var profile: Profile
    @Published var kernel: ExecutionKernel
    @Published var systemProxyActive: Bool
    /// 「怎么判」入口的状态行：当前生效的规则数（含 rule-provider 展开）。
    @Published var ruleCount: Int
    /// 「改成什么」入口的状态行：已加载的去广告规则数。
    @Published var adblockRuleCount: Int

    private let engine = LeapinEngine.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        let engine = self.engine
        kernel = engine.executionKernel
        state = engine.state
        profile = engine.profile
        systemProxyActive = engine.systemProxyActive
        ruleCount = engine.ruleCount
        adblockRuleCount = engine.adblockRuleCount

        engine.$executionKernel.receive(on: RunLoop.main).sink { [weak self] in self?.kernel = $0 }.store(in: &cancellables)
        engine.$state.receive(on: RunLoop.main).sink { [weak self] value in
            Task { @MainActor in
                self?.state = value
                self?.refreshCounts()
            }
        }.store(in: &cancellables)
        engine.$profile.receive(on: RunLoop.main).sink { [weak self] value in
            Task { @MainActor in
                self?.profile = value
                self?.refreshCounts()
            }
        }.store(in: &cancellables)
        engine.$systemProxyActive.receive(on: RunLoop.main).sink { [weak self] value in
            Task { @MainActor in self?.systemProxyActive = value }
        }.store(in: &cancellables)
    }

    /// 规则引擎与去广告引擎在启动 / 换配置时重建，计数也就变了。
    private func refreshCounts() {
        ruleCount = engine.ruleCount
        adblockRuleCount = engine.adblockRuleCount
    }
}

@MainActor
struct DashboardView: View {
    @EnvironmentObject private var app: AppModel
    var body: some View { DashboardContent(scenes: app.scenes, bookmarks: app.bookmarks) }
}

/// 「走哪」·总览：一条路（焦点带）→ 问一句 + 最近决策 → 另外三个动词 → 场景导轨。
///
/// 这一屏只回答两个问题：**现在走哪条**（焦点带里的出口，是全屏唯一的大字）和
/// **接下来去哪**（三个动词各带一句当前状态）。没接管时焦点带不装死：出口站
/// 直接写「还没有出口」，旁边就是这一个主操作。
@MainActor
private struct DashboardContent: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.lpWindowWidth) private var windowWidth
    @StateObject private var model = OverviewModel()
    /// 首屏只留 ≤5 个一级块（DESIGN-v5 §12.1）：书签、随手可用、公司与回家、页脚都收在这里。
    @State private var showMore = false
    /// v6：60 秒速率河。每秒一帧，只在本页可见时跑。
    @State private var river: [LPRiverSample] = Array(repeating: .zero, count: 60)
    @State private var frozen: Int?
    /// 可拖的出口：只在真正能切的时候（运行中且候选 > 1）才替换静态的展示。
    @State private var quickStops: [LPRouteScrubber.Stop] = []
    @State private var quickGroup: String?
    /// 「问路」框里的字。回车才问，不边打边跳页。
    @State private var ask = ""
    @FocusState private var askFocused: Bool
    /// 常驻事实的唯一数据源：与菜单栏面板、实时浮窗是同一个对象。
    ///
    /// 这里**只读** `status`，不采样、不持有定时器。store 的帧由三处低频驱动：
    /// 面板打开时（1 Hz）、浮窗可见时、菜单栏图标（引擎状态 / 系统代理 / 错误 /
    /// 配置变化各推一次）。速率差分因此仍然只发生一次，窗口与面板不会各算一套。
    @ObservedObject private var resident = ResidentStatusStore.shared
    @ObservedObject var scenes: NetworkScenes
    @ObservedObject var bookmarks: NetworkBookmarks

    private var status: ResidentStatus { resident.status }

    private var running: Bool { model.state == .running }

    private var activeScene: NetworkScene? {
        guard let active = scenes.active, scenes.profileID(for: active) == model.profile.id else { return nil }
        return active
    }
    private var connected: Bool { running && model.systemProxyActive }

    /// 另外三个动词。走哪自己不在里面：这一页就是它，首屏的焦点带已经把它的状态说完了。
    private static let indexedVerbs: [WorkbenchVerb] = [.howJudged, .whatChanged, .why]

    // MARK: 首屏

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                askRow
                verbIndex
                sceneRail
                moreToggle
                if showMore { moreContent }
            }
            .padding(.horizontal, LPSpace.inset)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .foregroundStyle(LP.text)
        // 面板与浮窗都没开时，store 没人喂帧，首屏的事实就是死值（出口恒「—」、
        // 速率恒 0、拦截数不涨）。所以首屏可见时像菜单栏面板那样自己驱动共享 store：
        // 采样驱动在视图里，速率差分仍只在 `ResidentStatusStore` 发生一次；`.task`
        // 在离开页面时自动取消，不留后台轮询，也没有全局定时器。
        .task { await driveResidentFacts() }
        .task { await riverLoop() }
        .task(id: model.state) { await loadQuickStops() }
        .onChange(of: model.state.label) { _, _ in Task { await refreshResidentExit() } }
        .onChange(of: model.profile.id) { _, _ in Task { await refreshResidentExit() } }
        // 这一页没有列表可过滤：⌘F 落到「问路」框，而不是弹命令面板。
        .onChange(of: app.searchFocusRequest) { _, _ in askFocused = true }
    }

    // MARK: 喂帧（与菜单栏面板同一模式）

    private var engine: LeapinEngine { app.engine }

    /// 首帧先取一次快照（出口只在 `MenuBarSnapshot` 里），再进 1 Hz 循环。
    /// 循环只调 `resident.update(from:)`：差分仍然只发生在 store 里一次，
    /// 这里既没有第二个差分器，也没有自己的计时状态。
    private func driveResidentFacts() async {
        await refreshResidentExit()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            resident.update(from: engine)
        }
    }

    /// 出口只有快照里有（`current` / `currentGroup`）：状态或配置一变就重取一次，
    /// store 会记住它，之后 1 Hz 的帧继续沿用。没有新增任何全局定时器。
    private func refreshResidentExit() async {
        let latest = await engine.menuBarSnapshot()
        resident.update(from: engine, snapshot: latest)
    }

    private func riverLoop() async {
        while !Task.isCancelled {
            let rates = status.rates
            river.removeFirst()
            river.append(LPRiverSample(down: normalize(rates.down), up: normalize(rates.up)))
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// 对数归一：1 KB/s 看得见，3 MB/s 封顶。
    private func normalize(_ bytesPerSecond: Double) -> Double {
        guard bytesPerSecond > 0 else { return 0 }
        return min(1, log1p(bytesPerSecond) / log1p(3_000_000))
    }

    // MARK: 焦点带（每屏唯一的一个）

    private var hero: some View {
        FocusBand {
            VStack(alignment: .leading, spacing: 18) {
                if running {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 24) {
                            route
                            Spacer(minLength: 16)
                            liveRates()
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            route
                            liveRates(alignment: .leading)
                        }
                    }
                } else {
                    // 没接管就没有「此刻的数字」：不摆一排 0 装作在跑。
                    route
                }
                // 活的那一层：最近 60 秒的上下行。引擎没开就不画一条死线。
                if running {
                    LPRiver(samples: river, frozenIndex: frozen,
                            enabled: true, onInk: true, height: 36) { index in
                        frozen = index
                    }
                    HStack(spacing: 6) {
                        Text(frozen.map { "−\(59 - $0)s · 回看中" } ?? "最近 60 秒")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LP.onInkTertiary)
                        Spacer(minLength: 0)
                        Text("拖动回看")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LP.onInkTertiary)
                    }
                }
                if let message = app.networkMessage {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(app.networkFailed ? Color(red: 1, green: 0.66, blue: 0.60) : LP.onInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                InkRule()
                heroFooter
            }
        }
    }

    /// 同一条路，三种状态只换出口站上的字：出口名 / 「没有可切换的节点」/「还没有出口」。
    private var route: some View {
        LPRouteScrubber(
            stops: routeStops,
            selectedID: status.exit ?? routeStops.first?.id ?? "",
            judge: judgeTitle,
            judgeDetail: running ? "\(model.ruleCount) 条规则" : nil,
            exitDetail: exitDetail,
            emptyExitTitle: parkedTitle,
            enabled: running,
            size: .hero,
            onInk: true
        ) { member in
            guard let group = quickGroup else { return }
            Task {
                try? await app.engine.menuBarSelect(group: group, member: member)
                await loadQuickStops()
            }
        }
    }

    private var routeStops: [LPRouteScrubber.Stop] {
        if quickStops.count > 1 { return quickStops }
        // 只有一个候选、或者根本拖不动：仍然把当前出口画出来，只是不给拖。
        if running, let exit = status.exit, !exit.isEmpty {
            return [.init(id: exit, label: exit, detail: "")]
        }
        return []
    }

    private var judgeTitle: String {
        if running { return activeScene?.title ?? "规则模式" }
        if case .failed = model.state { return "没能启动" }
        return "尚未接管"
    }

    private var parkedTitle: String {
        if case .failed = model.state { return "没能连上" }
        return running ? "没有可切换的节点" : "还没有出口"
    }

    /// 出口下面那一行：策略组 · 配置 · 延迟。没接管时它是一句人话，不是三个破折号。
    private var exitDetail: String? {
        if case .failed = model.state {
            return status.issues.first?.text ?? app.engine.lastError ?? "启动失败，原因见下方。"
        }
        guard running else {
            return "连上之后，这里显示每个请求走哪条路、有多快。"
        }
        var parts: [String] = []
        if let group = status.exitGroup, !group.isEmpty { parts.append(group) }
        if !status.profileName.isEmpty { parts.append(status.profileName) }
        if let latency = quickStops.first(where: { $0.id == status.exit })?.detail, !latency.isEmpty {
            parts.append(latency)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 实时速率：焦点带里唯一会每秒变一次的数字。
    private func liveRates(alignment: HorizontalAlignment = .trailing) -> some View {
        VStack(alignment: alignment, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                rate("arrow.down", status.rates.downText)
                rate("arrow.up", status.rates.upText)
            }
            Text("拦截 \(status.blocked) · \(status.connections) 个连接")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(LP.onInkSecondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func rate(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(LP.accentOnInk)
            Text(text)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(LP.onInk)
                .contentTransition(.numericText())
        }
    }

    /// §2.5 的一行事实 + 这一屏唯一的主操作。
    private var heroFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: status.coverage.isCoveringTraffic ? "checkmark.shield" : "exclamationmark.shield")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(status.coverage.isCoveringTraffic ? LP.mint : LP.accentOnInk)
            Text(status.coverage.declaration)
                .font(.system(size: 12))
                .foregroundStyle(LP.onInkSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if !connected {
                Button("导入配置") { app.beginImport() }
                    .buttonStyle(LPOnInkButtonStyle())
            }
            connectButton
        }
        .help(status.coverage.declaration)
    }

    /// 接管是这一屏唯一的主按钮；已经接管时「暂停」退成墨上的次按钮，不抢朱红。
    @ViewBuilder private var connectButton: some View {
        if connected {
            Button("暂停接管") { Task { await app.pauseNetwork() } }
                .buttonStyle(LPOnInkButtonStyle())
                .accessibilityLabel("暂停接管")
        } else {
            Button(app.networkBusy ? "准备中…" : "连接网络") { app.connectNetwork() }
                .buttonStyle(LPPrimaryButtonStyle())
                .disabled(app.networkBusy || app.engine.configurationBusy || model.state == .starting)
                .accessibilityLabel("连接网络")
        }
    }

    /// 菜单栏同一份快照：可切换的组与成员。失败就退回静态展示，不假装能拖。
    private func loadQuickStops() async {
        let snapshot = await app.engine.menuBarSnapshot()
        let groups = snapshot.nodeMenuGroups
        guard let group = groups.first(where: { $0.name == snapshot.currentGroup }) ?? groups.first else {
            quickStops = []
            quickGroup = nil
            return
        }
        quickGroup = group.name
        quickStops = group.members.map { node in
            LPRouteScrubber.Stop(
                id: node.name,
                label: node.name,
                detail: node.failed ? "失败" : (node.latencyMs.map { "\($0) ms" } ?? "")
            )
        }
    }

    // MARK: 问一句 + 最近决策

    /// 90 秒的那件事（某站点打不开）从这里开始：敲一个域名、回车，落到「为什么」
    /// 时判定已经在那里。右边是刚刚发生过的三条决策——任一个点开，就带着它去问。
    private var askRow: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                LPAskField(text: $ask,
                           placeholder: "输入域名，看它走哪条路",
                           focus: $askFocused) { text in askWhy(text) }
                    .frame(width: 340)
                Text("某个网站打不开？先问它走哪条路。")
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textTertiary)
            }
            Spacer(minLength: 8)
            if windowWidth >= 1100 { recentDecisions }
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder private var recentDecisions: some View {
        let recent = status.recent.prefix(3)
        if running, !recent.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                LPLabel("最近决策")
                ForEach(Array(recent)) { flow in
                    Button {
                        askWhy(flow.host)
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(decisionColor(flow.kind))
                                .frame(width: 6, height: 6)
                            Text(flow.host)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(LP.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(flow.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(decisionColor(flow.kind))
                                .lineLimit(1)
                        }
                        .frame(height: 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("带着 \(flow.host) 去「为什么」看它为什么这样走")
                    .accessibilityLabel("\(flow.host)，\(flow.label)，去为什么页查看")
                }
            }
            .frame(maxWidth: 420)
            .padding(.top, 1)
        }
    }

    private func decisionColor(_ kind: ResidentFlowKind) -> Color {
        switch kind {
        case .blocked: return LP.danger
        case .direct: return LP.mint
        case .proxy: return LP.accent
        case .other: return LP.textTertiary
        }
    }

    private func askWhy(_ text: String) {
        guard let target = SiteTarget(text) else {
            app.showToast("请输入域名或完整网址，例如 github.com", kind: .info)
            return
        }
        ask = ""
        app.routes.focus(RouteSubject(host: target.host, source: .dashboard))
        app.go(to: .why)
    }

    // MARK: 另外三个动词

    /// 一行目录，不是三张卡：和纸面一样安静，靠一条竖发丝线分开，各带一句当前状态。
    private var verbIndex: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(Self.indexedVerbs.enumerated()), id: \.element.id) { offset, verb in
                VerbCell(verb: verb, state: verbState(for: verb)) {
                    app.dispatch(.section(verb.sectionRaw))
                }
                if offset < Self.indexedVerbs.count - 1 {
                    Rectangle().fill(LP.line).frame(width: 1, height: 46).padding(.top, 2)
                }
            }
        }
    }

    /// 三入口各带一句当前状态：怎么判＝规则数，改成什么＝重写 / 去广告条目数，
    /// 为什么＝最近的拦截与刚刚的一条决策。
    private func verbState(for verb: WorkbenchVerb) -> VerbState {
        switch verb {
        case .goWhere:
            return VerbState(value: "", unit: "", caption: "")
        case .howJudged:
            return VerbState(value: "\(model.ruleCount)", unit: "条规则在判",
                             caption: model.profile.groups.isEmpty ? "没有策略组" : "\(model.profile.groups.count) 个策略组")
        case .whatChanged:
            return VerbState(value: "\(model.profile.rewrites.count)", unit: "条重写",
                             caption: "去广告 \(model.adblockRuleCount) 条")
        case .why:
            let latest = status.recent.first
            return VerbState(value: "\(status.blocked)", unit: "次拦截",
                             caption: latest.map { "刚刚：\($0.host)" } ?? "还没有连接")
        }
    }

    // MARK: 场景导轨

    /// 六个场景是一条导轨（模式选择器的读感），不是六颗胶囊：当前场景实心墨底，
    /// 绑过配置的是实心点，没绑的是空心圈——看一眼就知道哪几站能走。
    private var sceneRail: some View {
        let all = Array(NetworkScene.allCases)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                LPLabel("场景")
                Spacer()
                if let activeScene {
                    Button("调整当前场景") { app.sceneToConfigure = activeScene }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textSecondary)
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(all.enumerated()), id: \.offset) { offset, scene in
                    sceneSegment(scene)
                    if offset < all.count - 1,
                       activeScene != scene, offset + 1 < all.count, activeScene != all[offset + 1] {
                        Rectangle().fill(LP.line).frame(width: 1, height: 18)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
                    .fill(LP.sheet)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
                    .strokeBorder(LP.line, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous))
            Text(sceneCaption)
                .font(.system(size: 12))
                .foregroundStyle(LP.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sceneSegment(_ scene: NetworkScene) -> some View {
        let active = activeScene == scene
        let bound = scenes.profileID(for: scene) != nil
        let boundName = scenes.profileID(for: scene).flatMap { id in
            app.engine.profiles.first(where: { $0.id == id })?.name
        }
        return Button { app.switchScene(scene) } label: {
            HStack(spacing: 6) {
                Circle()
                    .strokeBorder(active ? LP.accentOnInk : LP.textTertiary.opacity(0.7), lineWidth: 1)
                    .background(Circle().fill(active ? LP.accentOnInk : (bound ? LP.text.opacity(0.6) : Color.clear)))
                    .frame(width: 7, height: 7)
                Text(scene.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(active ? LP.onInk : (bound ? LP.text : LP.textSecondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(active ? LP.ink : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(app.networkBusy)
        .help(boundName.map { "\(scene.detail)\n绑定：\($0)" } ?? "\(scene.detail)\n还没绑定配置，点了先选一份")
        .accessibilityLabel("\(scene.title)，\(bound ? "切换场景" : "未绑定方案")")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var sceneCaption: String {
        guard let activeScene else {
            return "点一个场景就切过去；还没绑配置的，会先让你选一份。"
        }
        if let id = scenes.profileID(for: activeScene),
           let name = app.engine.profiles.first(where: { $0.id == id })?.name {
            return running ? "使用中：\(activeScene.title) · \(name)" : "已选择：\(activeScene.title) · 连接后使用 \(name)"
        }
        return "使用中：\(activeScene.title)"
    }

    // MARK: 更多

    private var moreToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { showMore.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(showMore ? "收起" : "更多工具与设置")
                Image(systemName: showMore ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(LP.textSecondary)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showMore ? "收起更多" : "展开更多")
    }

    /// 折叠区。原来这里还有一排五个快捷按钮（分享 / 致谢 / 公司 / 导入 / 管理线路），
    /// 五个在侧栏和页头 tab 里都有同一落点的入口，重复一遍只是多一行要读的字。
    private var moreContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            bookmarksWidget
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("随手可用").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("⌘K 查找更多工具").font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                }
                VStack(spacing: 0) {
                    dashRow("开发与 Agent", icon: "curlybraces", note: "终端、App 分流与服务器",
                            actions: [("复制终端代理", { copyTerminal() }),
                                      ("App 分流", { app.go(to: .learn) }),
                                      ("连接服务器", { app.go(to: .ssh) })])
                    Divider().overlay(LP.stroke)
                    dashRow("HTTPS 调试通道", icon: "curlybraces.square", note: "mitmproxy 解密 · Mihomo 出站",
                            actions: [("调试一个网站", { app.networkToolPage = 1; app.showNetworkTools = true })])
                    Divider().overlay(LP.stroke)
                    dashRow("网站与网络体检", icon: "stethoscope", note: "检查目标、解释分流与连接异常",
                            actions: [("粘贴 URL 检查", { inspectClipboard() }),
                                      ("打开排障", { app.go(to: .diagnostics) })])
                    Divider().overlay(LP.stroke)
                    dashRow("保护与调试", icon: "lock.shield", note: "广告过滤、抓包与隐私设置",
                            actions: [("过滤与例外", { app.go(to: .adblock) }),
                                      ("抓包", { app.go(to: .capture) }),
                                      // T-13 要删掉 Privacy 页；这里不再指向一个即将不存在的
                                      // Section，隐私相关的开关与数据改去设置（HLD §4：隐私与数据）。
                                      ("隐私与数据", { app.go(to: .settings) })])
                }
                .lpSheet()
            }

            if windowWidth >= 900 {
                HStack(alignment: .top, spacing: 18) {
                    CompanyWidget(model: app.company)
                    HomeWidget(home: app.home)
                }
            } else {
                CompanyWidget(model: app.company)
                HomeWidget(home: app.home)
            }

            HStack(spacing: 12) {
                Image(systemName: "cpu").foregroundStyle(LP.textSecondary)
                // 配置名已经在「当前配置」里，这里只留内核：同一屏不重复同一个事实。
                Text("内核：\(model.kernel.title)")
                    .font(.system(size: 12)).foregroundStyle(LP.textSecondary).lineLimit(1)
                Spacer()
                Button("支持哪些协议？") { app.showCapabilities = true }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(LP.accent)
                Button("设置") { app.go(to: .settings) }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
            }.padding(.top, 4)
        }
    }

    private var bookmarksWidget: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("常用书签", systemImage: "bookmark").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("管理") { app.showBookmarks = true }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(LP.accent)
            }
            if bookmarks.items.isEmpty {
                Text("把常用网站放在这里，打开、检查，一步可达。")
                    .font(.system(size: 13)).foregroundStyle(LP.textSecondary)
                Spacer(minLength: 0)
                Button("添加网站") { app.showBookmarks = true }.buttonStyle(LPGhostButtonStyle())
            } else {
                ForEach(Array(bookmarks.items.prefix(3))) { bookmark in
                    HStack {
                        Button(bookmark.title) { NSWorkspace.shared.open(bookmark.url) }.buttonStyle(.plain)
                            .font(.system(size: 13)).foregroundStyle(LP.text).lineLimit(1)
                        Spacer()
                        Button("检查") { app.openTask(bookmark.url.absoluteString) }.buttonStyle(.plain)
                            .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                    }
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading).lpPanel(padding: 0)
    }

    private func dashRow(_ title: String, icon: String, note: String,
                         actions: [(String, () -> Void)]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(LP.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(LP.text)
                Text(note).font(.system(size: 12)).foregroundStyle(LP.textTertiary)
            }
            Spacer(minLength: 8)
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Button(action.0) { action.1() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(LP.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func copyTerminal() {
        let port = model.profile.general.mixedPort
        LPClipboard.copy("export http_proxy=http://127.0.0.1:\(port) https_proxy=http://127.0.0.1:\(port) all_proxy=socks5h://127.0.0.1:\(port) no_proxy=localhost,127.0.0.1,::1")
        app.showToast(model.state == .running ? "已复制终端代理环境命令" : "已复制；使用前请先启动网络服务", kind: .info)
    }
    private func inspectClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        if SiteTarget(text) != nil { app.openTask(text) }
        else { app.go(to: .diagnostics); app.requestSearchFocus(); app.showToast("请输入要检查的网站地址", kind: .info) }
    }
}

/// 目录里的一个入口：图标 + 动词名 + 快捷键，下面一个数和一句状态。
private struct VerbCell: View {
    let verb: WorkbenchVerb
    let state: VerbState
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: verb.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(hovering ? LP.accent : LP.textTertiary)
                        .frame(width: 16)
                    Text(verb.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LP.text)
                    Spacer(minLength: 6)
                    LPKeyCap(keys: "⌘\(verb.shortcut)")
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(state.value)
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LP.text)
                        .contentTransition(.numericText())
                    Text(state.unit)
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textSecondary)
                    Spacer(minLength: 4)
                }
                Text(state.caption)
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
                    .fill(hovering ? LP.sheet : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(LPCardButtonStyle(radius: LPRadius.control))
        .onHover { hovering = $0 }
        .lpAnimation(LPMotion.quick, value: hovering)
        .help("打开「\(verb.title)」")
        .accessibilityLabel("\(verb.title)，\(state.value) \(state.unit)，\(state.caption)")
    }
}

private struct VerbState {
    var value: String
    var unit: String
    var caption: String
}
