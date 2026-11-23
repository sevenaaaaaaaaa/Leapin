import SwiftUI
import Combine
import AppKit
import LeapinCore
import LeapinRuntime

/// A deliberately low-frequency snapshot of the engine: state, active profile and
/// configuration flags only. It never subscribes to flows or stats, so the
/// overview does not re-render on every connection.
///
/// 「走哪」首屏那五个事实**不在这里算**：它们来自 `ResidentStatusStore`（和菜单栏
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

/// 「走哪」·总览：五个事实 + 四个动词入口 + 场景条 + 快捷操作。
///
/// 首屏只回答两个问题：**现在走哪条**（五个事实）和**接下来点哪个动词**（四入口）。
/// 原来的「线路与订阅」统计块（配置名 + 节点数 / 策略组数 / 规则数）与首屏重复，
/// 已经删掉；导入与线路管理仍在「配置与订阅」tab 和收纳·导入里，能力没有少。
@MainActor
private struct DashboardContent: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.lpWindowWidth) private var windowWidth
    @StateObject private var model = OverviewModel()
    /// 五个事实的唯一数据源：与菜单栏面板、实时浮窗是同一个对象。
    ///
    /// 这里**只读** `status`，不采样、不持有定时器。store 的帧由三处低频驱动：
    /// 面板打开时（1 Hz）、浮窗可见时、菜单栏图标（引擎状态 / 系统代理 / 错误 /
    /// 配置变化各推一次）。速率差分因此仍然只发生一次，窗口与面板不会各算一套。
    @ObservedObject private var resident = ResidentStatusStore.shared
    @ObservedObject var scenes: NetworkScenes
    @ObservedObject var bookmarks: NetworkBookmarks

    private var status: ResidentStatus { resident.status }

    private var activeScene: NetworkScene? {
        guard let active = scenes.active, scenes.profileID(for: active) == model.profile.id else { return nil }
        return active
    }
    private var connected: Bool { model.state == .running && model.systemProxyActive }

    // MARK: 首屏

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                focusBand
                verbGrid
                HStack(spacing: 10) {
                    Button { app.networkToolPage = 0; app.showNetworkTools = true } label: { Label("分享本地服务", systemImage: "link") }.buttonStyle(LPGhostButtonStyle())
                    Button { app.networkToolPage = 2; app.showNetworkTools = true } label: { Label("工具与致谢", systemImage: "heart") }.buttonStyle(LPGhostButtonStyle())
                    Button { app.showCompany = true } label: { Label("公司内网", systemImage: "building.2") }.buttonStyle(LPGhostButtonStyle())
                    // 删掉「线路与订阅」统计块时一并丢掉的两个快捷动作（T-08 评审 optional）：
                    // 它们是操作，不是统计，属于任务书第 3 条「保留……快捷操作」。
                    Button { app.beginImport() } label: { Label("导入与转换订阅", systemImage: "square.and.arrow.down") }.buttonStyle(LPGhostButtonStyle())
                    Button { app.go(to: .profiles) } label: { Label("管理线路", systemImage: "slider.horizontal.3") }.buttonStyle(LPGhostButtonStyle())
                    Spacer(minLength: 0)
                }
                sceneRail
                bookmarksWidget
                HStack {
                    Text("随手可用").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("⌘K 查找更多工具").font(.system(size: 13)).foregroundStyle(LP.textSecondary)
                }
                VStack(alignment: .leading, spacing: 10) {
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
                    .background(LP.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(LP.stroke.opacity(0.5), lineWidth: 0.5))
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
                        .font(.system(size: 13)).foregroundStyle(LP.textSecondary).lineLimit(1)
                    Spacer()
                    Button("支持哪些协议？") { app.showCapabilities = true }.buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(LP.accent)
                    Button("设置") { app.go(to: .settings) }.buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(LP.textSecondary)
                }.padding(.top, 4)
            }.pagePadding()
        }
        .foregroundStyle(LP.text)
        // 面板与浮窗都没开时，store 没人喂帧，首屏五个事实就是死值（出口恒「—」、
        // 速率恒 0、拦截数不涨）。所以首屏可见时像菜单栏面板那样自己驱动共享 store：
        // 采样驱动在视图里，速率差分仍只在 `ResidentStatusStore` 发生一次；`.task`
        // 在离开页面时自动取消，不留后台轮询，也没有全局定时器。
        .task { await driveResidentFacts() }
        .onChange(of: model.state.label) { _, _ in Task { await refreshResidentExit() } }
        .onChange(of: model.profile.id) { _, _ in Task { await refreshResidentExit() } }
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

    // MARK: 焦点带（v5 §7）

    /// 一屏唯一的墨色焦点带：一条路 + 四个事实 + 一个主操作。
    /// 形状变了，取值没变——仍然全部来自 `ResidentStatusStore.shared.status`。
    private var focusBand: some View {
        FocusBand("现在走") {
            VStack(alignment: .leading, spacing: 22) {
                RouteLine(nodes: [
                    .init("你", subtitle: "这台 Mac"),
                    .init(judgeTitle, subtitle: "判据"),
                    .init(exitNodeTitle, subtitle: exitNodeSubtitle, state: .current),
                ])
                HStack(alignment: .bottom, spacing: 28) {
                    RouteFact("当前配置", profileText)
                    RouteFact("当前出口", exitText)
                    RouteFact("速率", status.rates.summary)
                    RouteFact("拦截数", "\(status.blocked)")
                    Spacer(minLength: 12)
                    connectButton
                }
                HStack(spacing: 6) {
                    Image(systemName: status.coverage.isCoveringTraffic ? "checkmark.shield" : "exclamationmark.shield")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(status.coverage.isCoveringTraffic ? LP.mint : LP.amber)
                    Text(status.coverage.declaration)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .help(status.coverage.declaration)
                if let message = app.networkMessage {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(app.networkFailed ? Color(red: 1, green: 0.55, blue: 0.5) : .white.opacity(0.62))
                }
            }
        }
    }

    private var judgeTitle: String {
        activeScene?.title ?? (model.state == .running ? "规则模式" : "尚未接管")
    }

    private var exitNodeTitle: String {
        guard model.state == .running, let exit = status.exit else { return "—" }
        return exit
    }

    private var exitNodeSubtitle: String {
        guard model.state == .running else { return "配置未接管" }
        if let group = status.exitGroup { return "\(group) › \(status.exit ?? "")" }
        return status.rates.summary
    }

    private var connectButton: some View {
        Button(connected ? "暂停接管" : app.networkBusy ? "准备中…" : "连接网络") {
            if connected { Task { await app.pauseNetwork() } } else { app.connectNetwork() }
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
                .fill(LP.accent.opacity(app.networkBusy ? 0.55 : 1))
        )
        .disabled(app.networkBusy || app.engine.configurationBusy || model.state == .starting)
        .accessibilityLabel(connected ? "暂停接管" : "连接网络")
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("你的网络，随需而行。")
                        .font(LPFont.display(28, weight: .semibold)).tracking(-0.5)
                    HStack(spacing: 7) {
                        // 状态行读 store 的标题（与面板同一个 tone、同一句话）；store 还没被
                        // 任何一面推过帧时（title 为空）才退回引擎自己的状态文案。
                        StatusDot(color: status.tone.ink, pulsing: model.state == .running)
                        Text(status.title.isEmpty ? model.state.label : status.title)
                            .font(.system(size: 13)).foregroundStyle(LP.textSecondary)
                        Text("·").font(.system(size: 13)).foregroundStyle(LP.textTertiary)
                        Text(activeScene?.title ?? "尚未选择场景")
                            .font(.system(size: 13)).foregroundStyle(LP.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                Button(connected ? "暂停接管" : app.networkBusy ? "准备中…" : "连接网络") {
                    if connected { Task { await app.pauseNetwork() } } else { app.connectNetwork() }
                }.buttonStyle(LPGhostButtonStyle()).disabled(app.networkBusy || app.engine.configurationBusy || model.state == .starting)
            }
            if let message = app.networkMessage {
                Text(message).font(.system(size: 13)).foregroundStyle(app.networkFailed ? LP.danger : LP.textSecondary)
            }
        }
    }

    // MARK: 五个事实

    /// 当前配置 / 当前出口 / 速率 / 拦截数，加底下「接管范围」一行（PRODUCT-v4 §2.5）。
    ///
    /// 五项的取值只用 `ResidentStatus` 自己的字段与格式化文本（`rates.summary`、
    /// `coverage.declaration`），所以菜单栏面板与这屏显示的是同一串字，不是两套算法。
    private var factStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                factCell("当前配置", profileText)
                factDivider
                factCell("当前出口", exitText)
                factDivider
                factCell("速率", status.rates.summary, numeric: true)
                factDivider
                factCell("拦截数", "\(status.blocked)", numeric: true)
            }
            HStack(spacing: 6) {
                Image(systemName: status.coverage.isCoveringTraffic ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(status.coverage.isCoveringTraffic ? LP.mint : LP.amber)
                Text(status.coverage.declaration)
                    .font(.system(size: 11))
                    .foregroundStyle(LP.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .help(status.coverage.declaration)
            .accessibilityElement(children: .combine)
        }
        .lpPanel()
    }

    private func factCell(_ label: String, _ value: String, numeric: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(LPFont.mono(10, weight: .medium))
                .tracking(0.9)
                .foregroundStyle(LP.textTertiary)
                .lineLimit(1)
            Text(value)
                .font(numeric ? LPFont.num(15, weight: .semibold) : .system(size: 14, weight: .semibold))
                .foregroundStyle(LP.text)
                .monospacedDigit()
                .lineLimit(1)
                // 速率那一行（「↓ 1.2 MB/s · ↑ 12 KB/s」）比列宽长：宁可缩一点，也别
                // 把箭头或单位截掉——首屏的数字必须读得出来。
                .minimumScaleFactor(0.75)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(value)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)：\(value)")
    }

    private var factDivider: some View {
        Rectangle().fill(LP.stroke).frame(width: 1, height: 30)
    }

    /// 与菜单栏面板同一写法：空配置显示「—」。
    private var profileText: String {
        status.profileName.isEmpty ? "—" : status.profileName
    }

    /// 与菜单栏面板的 `exitText` 逐字一致（`exitGroup › exit`），面板与本页才显示同一串。
    private var exitText: String {
        guard model.state == .running else { return "—" }
        guard let exit = status.exit else { return "没有可切换的节点" }
        let group = status.exitGroup.map { "\($0) › " } ?? ""
        return group + exit
    }

    // MARK: 四个动词入口

    private var verbGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                LPEyebrow("四个动词 / VERBS")
                Spacer(minLength: 8)
                Text("四个入口共用同一份上下文").font(.system(size: 11)).foregroundStyle(LP.textTertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(WorkbenchVerb.allCases) { verb in
                    verbCard(verb)
                }
            }
        }
    }

    /// 一个入口：标题 + 快捷键 + **一句当前状态**。点它走 `app.dispatch`，
    /// 与侧栏、「前往」菜单、命令面板同一条落点映射，不另开一条导航。
    private func verbCard(_ verb: WorkbenchVerb) -> some View {
        Button {
            app.dispatch(.section(verb.sectionRaw))
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: verb.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LP.accent)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(verb.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LP.text)
                        Spacer(minLength: 4)
                        LPKeyCap(keys: "⌘\(verb.shortcut)")
                    }
                    Text(stateLine(for: verb))
                        .font(.system(size: 11))
                        .foregroundStyle(LP.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LP.textTertiary)
                    .padding(.top, 3)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LP.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LP.stroke.opacity(0.7), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(LPCardButtonStyle(radius: 12))
        .help("打开「\(verb.title)」")
        .accessibilityLabel("\(verb.title)，\(stateLine(for: verb))")
    }

    /// 四入口各带一句当前状态：走哪＝配置与出口，怎么判＝规则数，
    /// 改成什么＝重写 / 去广告条目数，为什么＝最近拦截数。
    private func stateLine(for verb: WorkbenchVerb) -> String {
        switch verb {
        case .goWhere:
            return "\(profileText) · \(exitText)"
        case .howJudged:
            return "\(model.ruleCount) 条规则在判"
        case .whatChanged:
            return "重写 \(model.profile.rewrites.count) 条 · 去广告 \(model.adblockRuleCount) 条"
        case .why:
            return "最近拦截 \(status.blocked) 次"
        }
    }

    // MARK: 场景条

    private var sceneRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                LPEyebrow("场景 / SCENES")
                Spacer()
                if let activeScene {
                    Button("调整当前场景") { app.sceneToConfigure = activeScene }.buttonStyle(.plain)
                        .font(.system(size: 13)).foregroundStyle(LP.textSecondary)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(NetworkScene.allCases) { scene in
                    Button { app.switchScene(scene) } label: {
                        VStack(spacing: 8) {
                            Image(systemName: scene.icon).font(.system(size: 18))
                            Text(scene.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(scenes.profileID(for: scene) == nil ? "设置方案" : activeScene == scene ? (model.state == .running ? "使用中" : "已选择") : "可切换")
                                .font(.system(size: 11)).foregroundStyle(activeScene == scene ? LP.accent : LP.textTertiary)
                        }
                        .foregroundStyle(activeScene == scene ? LP.accent : LP.text)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(activeScene == scene ? LP.accent.opacity(0.09) : LP.text.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(activeScene == scene ? LP.accent.opacity(0.3) : LP.stroke))
                        .contentShape(Rectangle())
                    }.buttonStyle(LPCardButtonStyle(radius: 12)).disabled(app.networkBusy)
                        .help(scene.detail).accessibilityLabel("\(scene.title)，\(scenes.profileID(for: scene) == nil ? "未绑定方案" : "切换场景")")
                }
            }
        }
    }

    // MARK: 快捷操作

    private var bookmarksWidget: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("常用书签", systemImage: "bookmark").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("管理") { app.showBookmarks = true }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(LP.accent)
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
                            .font(.system(size: 13)).foregroundStyle(LP.textSecondary)
                    }
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, minHeight: 197, alignment: .topLeading).lpPanel(padding: 0)
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
                Text(note).font(.system(size: 11)).foregroundStyle(LP.textTertiary)
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

    private func textAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 13)).foregroundStyle(LP.textSecondary)
        }.buttonStyle(.plain)
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
