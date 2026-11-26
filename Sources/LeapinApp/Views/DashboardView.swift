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

/// 「走哪」·总览：一张浮在舞台上的纸。
///
/// 「现在走哪条」由舞台的天空回答（那条活的路、出口星、事实与主操作都在那里），
/// 这张纸只回答**接下来去哪**：问一句、另外三个动词、场景导轨、书签、公司与回家。
@MainActor
private struct DashboardContent: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.lpWindowWidth) private var windowWidth
    @StateObject private var model = OverviewModel()
    @State private var showMore = false
    /// 「问路」框里的字。回车才问，不边打边跳页。
    @State private var ask = ""
    @FocusState private var askFocused: Bool
    /// 只读：store 的帧由舞台驱动（它常驻），这里不采样、不持有定时器。
    @ObservedObject private var resident = ResidentStatusStore.shared
    @ObservedObject var scenes: NetworkScenes
    @ObservedObject var bookmarks: NetworkBookmarks

    private var status: ResidentStatus { resident.status }

    private var running: Bool { model.state == .running }

    private var activeScene: NetworkScene? {
        guard let active = scenes.active, scenes.profileID(for: active) == model.profile.id else { return nil }
        return active
    }

    /// 另外三个动词。走哪自己不在里面：这一页就是它，天空已经把它的状态说完了。
    private static let indexedVerbs: [WorkbenchVerb] = [.howJudged, .whatChanged, .why]

    // MARK: 首屏

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                askRow
                verbIndex
                sceneRail
                // 书签与公司 / 回家不折叠：它们不依赖引擎状态，没接管时也用得上，
                // 比一整片空白强。「随手可用」清单和内核页脚才收进「更多」。
                bookmarksWidget
                companyHomeRow
                moreToggle
                if showMore { moreContent }
            }
            .padding(.horizontal, LPSpace.inset)
            .padding(.vertical, 20)
        }
        .foregroundStyle(LP.text)
        // 这一页没有列表可过滤：⌘F 落到「问路」框，而不是弹命令面板。
        .onChange(of: app.searchFocusRequest) { _, _ in askFocused = true }
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

    /// 折叠区只收两样：「随手可用」清单和内核页脚。书签与公司 / 回家不在这里——
    /// 它们不依赖引擎状态，没接管时也用得上，压在「更多」里等于藏了半屏空白的解药。
    private var moreContent: some View {
        VStack(alignment: .leading, spacing: 22) {
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
                            actions: [("调试一个网站", { app.networkToolPage = 1; app.go(to: .tools) })])
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

            HStack(spacing: 12) {
                Image(systemName: "cpu").foregroundStyle(LP.textSecondary)
                // 配置名已经在舞台的出口星下写着，这里只留内核：同一屏不重复同一个事实。
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

    /// 公司内网与回家两块卡：宽窗口并排，窄窗口上下。
    @ViewBuilder private var companyHomeRow: some View {
        if windowWidth >= 900 {
            HStack(alignment: .top, spacing: 18) {
                CompanyWidget(model: app.company)
                HomeWidget(home: app.home)
            }
        } else {
            CompanyWidget(model: app.company)
            HomeWidget(home: app.home)
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
