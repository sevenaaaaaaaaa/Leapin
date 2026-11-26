import SwiftUI
import Combine
import AppKit
import LeapinRuntime
import LeapinCore
import LeapinIntegrations
import LeapinPolicy
import LeapinNet

@main
@MainActor
struct LeapinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel()

    var body: some Scene {
        Window("Leapin", id: "main") {
            RootView()
                .environmentObject(app)
                .onAppear { appDelegate.stopExternalTools = { app.sharing.stop(force: true); app.debugChannel.stop(force: true) } }
                .frame(minWidth: 900, minHeight: 660)
        }
        .defaultSize(width: 1240, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("重新载入配置") { Task { await app.engine.reloadProfile() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .appSettings) {
                Button("设置…") { app.go(to: .settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .importExport) {
                Button("导入配置…") { app.showImporter = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("导出 Clash 配置…") { app.exportProfile(format: .clash) }
                Button("导出 Hosts 拦截表…") { app.exportProfile(format: .hosts) }
                Button("导出 ABP 过滤列表…") { app.exportProfile(format: .abp) }
                Button("导出 Clash rule-set…") { app.exportProfile(format: .ruleSet) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }

            CommandMenu("工具") {
                Button("显示 / 隐藏实时浮窗") {
                    FloatingPanelController.shared.toggle()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("打开数据目录") {
                    NSWorkspace.shared.open(app.engine.store.root)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("安装 / 打开根证书") { app.installCA() }
                Button("复制代理地址") {
                    LPClipboard.copy("127.0.0.1:\(app.engine.profile.general.mixedPort)")
                    app.showToast("已复制 127.0.0.1:\(app.engine.profile.general.mixedPort)", kind: .success)
                }
                Divider()
                Button("重新显示上手引导") {
                    UserDefaults.standard.set(false, forKey: "lp.onboarded")
                    app.showOnboarding = true
                }
            }

            CommandMenu("前往") {
                Button("命令面板…") { app.showPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("搜索当前页面") { app.requestSearchFocus() }
                    .keyboardShortcut("f", modifiers: .command)
                Divider()
                // 11 行与侧栏同源（WorkbenchSidebar）：四个动词按计划里的 shortcut 挂
                // ⌘1..⌘4，其余行不给键位——菜单和侧栏不该有两份顺序和两套键。
                ForEach(WorkbenchSidebar.rows.filter { $0.shortcut != nil }) { row in
                    Button(row.title) { app.dispatch(row.destination) }
                        .keyboardShortcut(Self.key(for: row.shortcut ?? ""), modifiers: .command)
                }
                ForEach(WorkbenchSidebar.rows.filter { $0.shortcut == nil }) { row in
                    Button(row.title) { app.dispatch(row.destination) }
                }
                Divider()
                Button("启动 / 停止代理") { app.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button(app.engine.systemProxyActive ? "关闭系统代理" : "开启系统代理") {
                    Task { await app.engine.toggleSystemProxy(!app.engine.systemProxyActive) }
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(app)
        } label: {
            MenuBarLabel()
        }
        // A window-style extra is what makes the node search field, the scroll
        // list and the nested menus usable; menu style cannot host them.
        .menuBarExtraStyle(.window)
    }

    /// ⌘1..⌘4 的键位来自 `WorkbenchSidebar`（T-05），App 只做 String → KeyEquivalent，
    /// 不再自己维护一份「第几个 Section 配第几个数字」的副本。
    private static func key(for shortcut: String) -> KeyEquivalent {
        KeyEquivalent(shortcut.first ?? "?")
    }
}

@MainActor
final class AppModel: ObservableObject {
    /// Pre-filled rule seeded from a captured request; the rewrite page consumes it
    /// and opens the editor so the user confirms before anything is saved.
    @Published var pendingRewriteLine: String?
    /// 导航页。`.why` 是 M2 新增的「为什么」动词页；`.capture` 保留为它的深链 alias：
    /// 两个 rawValue 都落到 `WhyPage`，侧栏与「前往」菜单只列 `why` 一行。
    enum Section: String, CaseIterable, Identifiable {
        case dashboard, rules, rewrite, adblock, capture, why, ssh, nas, learn, profiles, settings, activity, diagnostics
        case home, company, tools
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dashboard: return "总览"
            case .rules: return "分流规则"
            case .rewrite: return "请求重写"
            case .adblock: return "去广告"
            case .capture: return "抓包"
            case .why: return "为什么"
            case .ssh: return "SSH"
            case .nas: return "NAS"
            case .learn: return "智能学习"
            case .profiles: return "线路与订阅"
            case .settings: return "设置"
            case .activity: return "网络活动"
            case .diagnostics: return "排障与配置"
            case .home: return "回家"
            case .company: return "公司内网"
            case .tools: return "分享与调试"
            }
        }
        var icon: String {
            switch self {
            case .dashboard: return "gauge.with.dots.needle.67percent"
            case .rules: return "arrow.triangle.branch"
            case .rewrite: return "arrow.triangle.2.circlepath"
            case .adblock: return "hand.raised.fill"
            case .capture: return "waveform.path.ecg"
            case .why: return "waveform.path.ecg"
            case .ssh: return "terminal"
            case .nas: return "externaldrive.connected.to.line.below"
            case .learn: return "brain"
            case .profiles: return "doc.on.doc"
            case .settings: return "gearshape"
            case .activity: return "waveform.path"
            case .diagnostics: return "stethoscope"
            case .home: return "house"
            case .company: return "building.2"
            case .tools: return "link"
            }
        }
        /// 该页面是否真的有可聚焦的搜索框（⌘F 只在 true 的页面上生效）。
        var supportsSearch: Bool {
            switch self {
            case .rules, .rewrite, .capture, .why, .adblock, .profiles, .activity, .diagnostics: return true
            case .dashboard, .ssh, .nas, .learn, .settings, .home, .company, .tools: return false
            }
        }

        var subtitle: String {
            switch self {
            case .dashboard: return "场景、常用资源与便捷操作"
            case .rules: return "Clash / Surge 规则、策略组与规则集"
            case .rewrite: return "改请求头、改响应正文、Mock 接口与重定向"
            case .adblock: return "过滤列表、拦截统计与白名单"
            case .capture: return "HTTP(S) 请求抓取与 HAR 导出"
            case .why: return "命中链、探测与诊断"
            case .ssh: return "交互式终端，密码经 askpass 传递"
            case .nas: return "Bonjour 发现与 SMB 挂载"
            case .learn: return "从 App 列表或截图生成分流规则"
            case .profiles: return "配置导入、导出与切换"
            case .settings: return "端口、DNS、抓包与日志"
            case .activity: return "连接明细、流量与分流路径"
            case .diagnostics: return "网站检查、规则调整与可恢复操作"
            case .home: return "绑定家庭设备，检查并打开 NAS 或 Web 服务"
            case .company: return "内网资源与接入方式，多公司保存、单公司启用"
            case .tools: return "限时分享本地服务、HTTPS 调试通道与工具致谢"
            }
        }

        /// 这个 rawValue 现在落在哪个动词页；不是动词页的返回 nil。
        ///
        /// T-13 的收口表：退役页不再有自己的身体，只作为深链 alias 落进某个动词页的某个 tab
        /// （profiles → 走哪·配置与订阅、adblock → 改成什么·去广告、activity → 为什么·指标、
        /// diagnostics → 为什么·诊断、capture → 为什么·连接）。页头从这里取名字，
        /// 于是「标题写的页」和「身体画的页」不可能对不上。
        var verb: WorkbenchVerb? {
            switch self {
            case .dashboard, .profiles: return .goWhere
            case .rules: return .howJudged
            case .rewrite, .adblock: return .whatChanged
            case .why, .capture, .activity, .diagnostics: return .why
        case .ssh, .nas, .learn, .settings, .home, .company, .tools: return nil
        }
    }

        /// 页头标题用动词名（dashboard → 走哪、why/capture → 为什么），其余页沿用页面名。
        var headerTitle: String { verb?.title ?? title }

        /// 页头图标跟着落点走，不跟旧 rawValue 走。
        var headerIcon: String { verb?.icon ?? icon }

        /// 页头副标题：动词页写用户的那句原话（`WorkbenchVerb.question`），其余页沿用页面副标题。
        ///
        /// 动词名只有两三个字，单独当标题对新用户不够自明；那句原话才是这一页在回答的问题。
        /// tab 名不再写在这里——它们现在就排在标题旁边。
        var headerSubtitle: String { verb?.question ?? subtitle }
    }

    let engine = LeapinEngine.shared
    /// 四个动词共享的上下文（T-05 的纯逻辑）。根视图把它下发给整棵树，
    /// WhyPage 从 T-07 起在 onAppear 里 take 一次。
    let routes = RouteContext()
    let assistant = NetworkAssistantModel()
    let scenes = NetworkScenes(root: LeapinEngine.shared.store.root)
    let bookmarks = NetworkBookmarks(root: LeapinEngine.shared.store.root)
    let home = HomeConnections(root: LeapinEngine.shared.store.root)
    let company = CompanyAccess(root: LeapinEngine.shared.store.root)
    @Published var companyResourceFocus: UUID?
    let sharing = ServiceSharing()
    let debugChannel = DebugChannel(root: LeapinEngine.shared.store.root)
    @Published var networkToolPage = 0
    @Published var showImportCenter = false
    @Published var pendingImport: ImportPreparation?
    @Published var showCapabilities = false
    @Published var sceneToConfigure: NetworkScene?
    @Published var showBookmarks = false
    @Published var networkBusy = false
    @Published var networkMessage: String?
    @Published var networkFailed = false

    @Published var section: Section? = .dashboard
    /// 当前页交给页头的 tab（见 `lpHeaderTabs`）。页头只负责画；选中的是哪一个、
    /// 怎么切，都还是页面自己的状态，壳这边不留第二份。
    @Published var headerTabs: LPHeaderTabs?
    @Published var toast: String?
    @Published var toastKind: LPToastKind = .success
    @Published var toastActionTitle: String?
    @Published var toastAction: (() -> Void)?
    @Published var showImporter = false
    @Published var showCAInstaller = false
    @Published var showPalette = false
    @Published var showOnboarding = false
    /// 最近一次导入的解析报告（为空表示还没有导入过）。
    @Published var importReport: ImportReport?
    @Published var showImportReport = false
    /// Bumped whenever something asks the current page to focus its search field.
    @Published var searchFocusRequest = 0
    /// 启动时默认打开的页面（设置在设置页里改）。
    @Published var startSectionPref: Section = .dashboard
    @Published var launchAtLogin = false
    @Published var autostartProxy = false

    private var externalToolsLifecycle: AnyCancellable?
    init() {
        externalToolsLifecycle = engine.$state.dropFirst().sink { [weak self] state in
            if state != .running { self?.debugChannel.stop() }
        }
        if let raw = UserDefaults.standard.string(forKey: "startSection"),
           let s = Section(rawValue: raw) {
            section = s
            startSectionPref = s
        }
        launchAtLogin = LaunchAtLogin.isEnabled
        autostartProxy = ProcessInfo.processInfo.environment["LEAPIN_AUTOSTART"] == "1"
            || UserDefaults.standard.bool(forKey: "autostartProxy")
        Task { await engine.refreshSystemProxyStatus() }
        if !UserDefaults.standard.bool(forKey: "lp.onboarded") {
            showOnboarding = true
        }
    }

    var isRunning: Bool { engine.state == .running }

    // MARK: Feedback

    func showToast(_ text: String,
                   kind: LPToastKind = .success,
                   actionTitle: String? = nil,
                   action: (() -> Void)? = nil) {
        toastKind = kind
        toastActionTitle = actionTitle
        toastAction = action
        toast = text
    }

    // MARK: Navigation

    func go(to section: Section) {
        LPMotion.run(LPMotion.press) { self.section = section }
        UserDefaults.standard.set(section.rawValue, forKey: "startSection")
    }

    /// 侧栏 /「前往」菜单 / 命令面板共用的一条落点映射。
    ///
    /// 行数据在 `WorkbenchSidebar`（T-05 的纯数据），这里只把它变成动作，
    /// 所以三个入口不会各自解释一遍「sheet 是哪一张」「导入走哪个门」。
    func dispatch(_ destination: WorkbenchDestination) {
        switch destination {
        case .section(let raw):
            // 落点写错的代价不该是崩一屏：忽略，交给静态断言去发现。
            guard let target = Section(rawValue: raw) else { return }
            go(to: target)
        case .importCenter:
            beginImport()
        }
    }

    /// ⌘F 落到当前页真正的输入框上。总览没有列表可过滤，它的输入框是「问路」；
    /// 其余没有搜索框的页面改为打开命令面板，避免「按了没反应」的假入口。
    func requestSearchFocus() {
        let page = section ?? .dashboard
        if page == .dashboard { searchFocusRequest += 1; return }
        guard page.supportsSearch else {
            showPalette = true
            showToast("\(page.title)没有搜索框，已打开命令面板", kind: .info)
            return
        }
        searchFocusRequest += 1
    }

    func setStartSection(_ target: Section) {
        startSectionPref = target
        UserDefaults.standard.set(target.rawValue, forKey: "startSection")
    }

    func setAutostartProxy(_ enabled: Bool) {
        autostartProxy = enabled
        UserDefaults.standard.set(enabled, forKey: "autostartProxy")
        showToast(enabled ? "下次启动会同时开启代理" : "下次启动只打开界面", kind: .info)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if let failure = LaunchAtLogin.set(enabled) {
            launchAtLogin = LaunchAtLogin.isEnabled
            showToast("登录项设置失败：\(failure)", kind: .error)
        } else {
            launchAtLogin = LaunchAtLogin.isEnabled
            showToast(launchAtLogin ? "已设为登录时启动" : "已取消登录时启动", kind: .success)
        }
    }

    /// leapin://section/rules, leapin://toggle, leapin://palette, leapin://proxy/on
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "leapin" else { return }
        let parts = ([url.host] + url.pathComponents.filter { $0 != "/" }).compactMap { $0?.lowercased() }
        guard let head = parts.first else { showPalette = true; return }
        switch head {
        case "section", "go":
            if parts.count > 1, let target = Section(rawValue: parts[1]) { go(to: target) }
        case "toggle":
            toggle()
        case "palette", "search":
            showPalette = true
        case "proxy":
            let on = parts.count > 1 ? parts[1] == "on" : !engine.systemProxyActive
            Task { await engine.toggleSystemProxy(on) }
        case "capture":
            go(to: .capture)
        default:
            if let target = Section(rawValue: head) { go(to: target) }
        }
    }

    // MARK: Actions

    func openTask(_ text: String) {
        assistant.prepare(text)
        go(to: .diagnostics)
    }

    /// One user action owns the two dependent steps. Never point macOS at an
    /// unbound listener. The durable message is also visible on the workspace.
    func connectNetwork() {
        guard !networkBusy, !engine.configurationBusy, engine.state != .starting else { return }
        networkBusy = true
        networkFailed = false
        networkMessage = "正在启动服务；就绪后接入系统代理…"
        Task {
            engine.lastError = nil
            if engine.state != .running { await engine.start() }
            if engine.state == .running {
                await engine.toggleSystemProxy(true)
            }
            networkFailed = engine.state != .running || !engine.systemProxyActive || engine.lastError != nil
            networkMessage = networkFailed
                ? "未完成连接：\(engine.lastError ?? "服务未就绪")。可重试或在设置中检查端口。"
                : "系统代理已接入。未测试具体网站；遇到访问问题可在下方输入网站检查。"
            if networkFailed { assistant.inspectLocal() }
            networkBusy = false
        }
    }

    func inspectCompanyResource(_ resource: CompanyResource) {
        companyResourceFocus = resource.id; go(to: .company)
        let port = engine.diagnosticProxyPort
        let profile = engine.profile
        let started = engine.stats.startedAt
        let systemProxy = engine.systemProxyActive
        Task { await company.check(resource, proxyPort: port, contextValid: {
            self.engine.profile == profile && self.engine.stats.startedAt == started && self.engine.diagnosticProxyPort == port && self.engine.systemProxyActive == systemProxy
        }) }
    }

    func openCompanyResource(_ resource: CompanyResource) async {
        guard let active = company.active, active.resources.contains(resource) else { return }
        do { try engine.refreshHomeRouting() }
        catch { company.notice(error.localizedDescription, failed: true); go(to: .company); return }
        if active.method.isProxy {
            await engine.refreshSystemProxyStatus()
            guard engine.state == .running, engine.systemProxyActive else {
                company.notice("浏览器尚未通过 Leapin 使用内网代理。请先接入系统代理，或在目标 App 手动设置 Leapin 代理。", failed: true)
                go(to: .company); return
            }
            guard !resource.matchesProxyBypass(engine.profile.general.bypass) else {
                company.notice("此地址匹配系统代理绕过列表，直接打开浏览器可能不经过内网代理。请在设置核对绕过规则，或为目标 App 单独配置代理。", failed: true)
                go(to: .company); return
            }
        }
        if !NSWorkspace.shared.open(resource.url) { company.notice("系统没有打开此类地址的应用，请使用对应的官方客户端。", failed: true); go(to: .company) }
    }

    func openHome() {
        guard !home.busy, !engine.configurationBusy, engine.state != .starting else { return }
        guard home.saved != nil else { go(to: .home); return }
        Task {
            if let url = await home.verifySaved(applyRouting: { try self.engine.refreshHomeRouting() }) {
                NSWorkspace.shared.open(url)
            } else { go(to: .home) }
        }
    }

    func pauseNetwork() async {
        guard !networkBusy, !engine.configurationBusy else { return }
        engine.lastError = nil
        await engine.toggleSystemProxy(false)
        networkFailed = engine.systemProxyActive || engine.lastError != nil
        networkMessage = networkFailed
            ? "暂停失败：\(engine.lastError ?? "请重试")"
            : "已暂停系统代理。本地服务仍可供手动配置的 App 使用。"
    }

    func toggle() {
        guard !engine.configurationBusy else { showToast("正在启用配置，请稍后操作", kind: .info); return }
        Task {
            if engine.state == .running {
                engine.stop()
                showToast("代理已停止", kind: .info)
            } else {
                await engine.start()
                if let error = engine.lastError {
                    showToast(error, kind: .error)
                } else if engine.state == .running {
                    showToast("代理已启动 · 127.0.0.1:\(engine.profile.general.mixedPort)")
                }
            }
        }
    }

    func beginImport() {
        pendingImport = nil
        showImportCenter = true
    }

    func importProfile(url: URL) {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
                throw LeapinError.invalidConfiguration("请选择 8 MB 内的 UTF-8 配置")
            }
            pendingImport = try ImportPreparation(text: text, name: url.deletingPathExtension().lastPathComponent,
                origin: url.lastPathComponent, pathExtension: url.pathExtension)
            showImportCenter = true
        } catch { showToast(Redactor.redact(error.localizedDescription), kind: .error) }
    }

    func importFromClipboardLink() {
        let raw = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Task {
            do {
                pendingImport = try await ImportPreparation.download(raw, name: "")
                showImportCenter = true
            } catch { showToast(Redactor.redact(error.localizedDescription), kind: .error) }
        }
    }

    func switchScene(_ scene: NetworkScene, profileID: UUID? = nil) {
        guard !networkBusy, !engine.configurationBusy else { return }
        guard let id = profileID ?? scenes.profileID(for: scene), engine.profiles.contains(where: { $0.id == id }) else {
            sceneToConfigure = scene
            return
        }
        networkBusy = true
        Task {
            if engine.profile.id != id { await engine.activate(id) }
            do {
                guard engine.profile.id == id, engine.lastError == nil else {
                    throw LeapinError.connectionFailed(engine.lastError ?? "场景配置无法启用")
                }
                try scenes.bind(scene, to: id)
                try scenes.markActive(scene)
                sceneToConfigure = nil
                showToast(engine.state == .running
                    ? "已切换到\(scene.title) · \(engine.profile.name)"
                    : "已选择\(scene.title) · 连接后使用\(engine.profile.name)")
            } catch { showToast(Redactor.redact(error.localizedDescription), kind: .error) }
            networkBusy = false
        }
    }

    func exportProfile(format: ProfileFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "leapin-\(format.cliName).\(format.fileExtension)"
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text: String
            if format == .clash, let source = try engine.store.kernelSource(for: engine.profile.id), source.kernel == .mihomo {
                text = source.clash
            } else { text = try engine.exportProfile(format) }
            try text.write(to: url, atomically: true, encoding: .utf8)
            let name = url.lastPathComponent
            showToast("已导出到 \(name)", kind: .success, actionTitle: "在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            showToast("导出失败：\(error.localizedDescription)", kind: .error)
        }
    }

    /// 按 id 导出任意一份配置（书架详情卡用），不改当前配置。
    /// 与 exportProfile(format:) 的差别只有一处：这里先按 id 把配置读出来。
    func exportProfile(id: UUID, name: String, format: ProfileFormat) {
        let panel = NSSavePanel()
        let safe = name.replacingOccurrences(of: "/", with: "-")
                       .replacingOccurrences(of: ":", with: "-")
                       .trimmingCharacters(in: .whitespaces)
        panel.nameFieldStringValue = "leapin-\(safe.isEmpty ? "profile" : safe).\(format.fileExtension)"
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let profile = try engine.store.load(id: id)
            let text: String
            if format == .clash,
               let source = try engine.store.kernelSource(for: id),
               source.kernel == .mihomo {
                text = source.clash
            } else {
                text = try engine.store.export(profile, format: format)
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
            showToast("已导出到 \(url.lastPathComponent)", kind: .success, actionTitle: "在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            showToast("导出失败：\(error.localizedDescription)", kind: .error)
        }
    }

    func installCA() {
        let caURL = engine.store.root.appendingPathComponent("ca/ca.pem")
        guard FileManager.default.fileExists(atPath: caURL.path) else {
            showToast("请先在设置中开启 HTTPS 解密并启动一次代理以生成 CA", kind: .warning)
            return
        }
        NSWorkspace.shared.open(caURL)
        showToast("已打开 CA 证书，请在“钥匙串访问”中添加并设为始终信任", kind: .info)
    }
}

@MainActor
struct RootView: View {
    @EnvironmentObject private var app: AppModel
    private let engine = LeapinEngine.shared

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 960
            ZStack {
                LPBackground()
                HStack(spacing: 0) {
                    SidebarView(compact: compact)
                        // 侧栏的上缘和页头标题的上缘在同一条线上（标题栏之下同样 12pt）；
                        // 红黄绿三个按钮在它上方的纸面上。
                        .padding(.leading, 10)
                        .padding(.top, LPShell.headerTop)
                        .padding(.bottom, 12)
                    VStack(spacing: 0) {
                        PageHeaderBar(compact: compact)
                        pageContent
                    }
                }
            }
            .environment(\.lpWindowWidth, geo.size.width)
        }
        .background(WindowAutosave())
        .environmentObject(app.routes)
        .overlay(alignment: .bottom) { toastView }
        .overlay {
            if app.showPalette {
                CommandPalette()
                    .environmentObject(app)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .lpAnimation(LPMotion.quick, value: app.showPalette)
        .sheet(isPresented: $app.showOnboarding) {
            OnboardingView().environmentObject(app)
        }
        .sheet(isPresented: $app.showImportCenter) { ImportCenter().environmentObject(app) }
        .sheet(isPresented: $app.showCapabilities) { KernelCapabilitiesView().environmentObject(app) }
        .sheet(item: $app.sceneToConfigure) { scene in SceneConfigurationView(scene: scene).environmentObject(app) }
        .sheet(isPresented: $app.showBookmarks) { BookmarksView(store: app.bookmarks).environmentObject(app) }
        .sheet(isPresented: $app.showImportReport) {
            if let report = app.importReport {
                ImportReportSheet(report: report) { app.showImportReport = false }
            }
        }
        .preferredColorScheme(ProcessInfo.processInfo.environment["LEAPIN_APPEARANCE"] == "dark" ? .dark : nil)
        .task {
            if app.autostartProxy, engine.state != .running {
                await engine.start()
            }
        }
        .onOpenURL { app.handle(url: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .lpNavigate)) { note in
            if let raw = note.object as? String, let section = AppModel.Section(rawValue: raw) {
                app.go(to: section)
            }
            // 外链、菜单栏面板跳页时要把窗口带到人面前；离屏快照只是自己翻页，不抢前台。
            if !LPShooting.isOn {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lpTogglePalette)) { _ in
            app.showPalette.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lpSearchFocus)) { _ in
            app.requestSearchFocus()
        }
        .fileImporter(isPresented: $app.showImporter,
                      allowedContentTypes: [.yaml, .plainText, .json, .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                _ = url.startAccessingSecurityScopedResource()
                defer { url.stopAccessingSecurityScopedResource() }
                app.importProfile(url: url)
            }
        }
    }

    /// One glass container per page: panels blend with each other instead of
    /// each spawning an independent material, which is both cheaper and the
    /// behaviour Apple's guidance asks for.
    @ViewBuilder private var pageContent: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { loadedSection }
        } else {
            loadedSection
        }
    }

    private var loadedSection: some View {
        ZStack {
            sectionContent
                .id(app.section ?? .dashboard)
                .transition(.opacity.combined(with: .offset(y: 6)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lpAnimation(LPMotion.standard, value: app.section)
    }

    /// T-13 的收口表：**每个 rawValue 只落一个视图**，退役页作为深链 alias 落进动词页的某个 tab。
    ///
    /// - 走哪：dashboard → 总览、profiles → 配置与订阅
    /// - 怎么判：rules
    /// - 改成什么：rewrite、adblock（同一页，页内切到「去广告」tab）
    /// - 为什么：why / capture → 连接、activity → 指标、diagnostics → 诊断
    ///
    /// 旧页名（网络活动 / 排障与配置 / 线路与订阅 / 去广告）不再有自己的入口，
    /// 但 rawValue 全部保留：外链、旧 defaults 里的 startSection 和通知还能落到同一页。
    @ViewBuilder private var sectionContent: some View {
        switch app.section ?? .dashboard {
        case .dashboard: GoWherePage(initialTab: .overview)
        case .profiles: GoWherePage(initialTab: .profiles)
        case .rules: RulesView()
        case .rewrite: RewriteView()
        // RewriteView 没有 initialTab：它固定从「重写」进，去广告是页内第四个 tab。
        // 旧深链值不值得再加一个 initialTab 参数？不值得——多一个参数就多一处可漂的默认值。
        case .adblock: RewriteView()
        case .why, .capture: WhyPage(initialTab: .connections)
        case .activity: WhyPage(initialTab: .metrics)
        case .diagnostics: WhyPage(initialTab: .diagnostics)
        case .ssh: SSHView()
        case .nas: NASView()
        // 侧栏不列 learn：它已降级成「怎么判」底部的学习建议入口，但独立页保留。
        case .learn: LearnView()
        case .settings: SettingsView()
        // 原来是三张工具 sheet（T-05 的落点表里也是 sheet）：侧栏长得一样的入口必须
        // 做同一件事，所以回家 / 公司内网 / 分享与调试和 SSH、NAS 一样是页面。
        case .home: HomeConnectionView(home: app.home)
        case .company: CompanyAccessView(model: app.company)
        case .tools: NetworkToolsView(sharing: app.sharing, debug: app.debugChannel)
        }
    }

    @ViewBuilder private var toastView: some View {
        if let message = app.toast {
            ToastOverlay(text: message,
                         kind: app.toastKind,
                         actionTitle: app.toastActionTitle,
                         action: app.toastAction,
                         onDismiss: { app.toast = nil })
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: message) {
                    try? await Task.sleep(nanoseconds: 3_200_000_000)
                    guard app.toast == message else { return }
                    LPMotion.run(LPMotion.standard) {
                        app.toast = nil
                        app.toastAction = nil
                    }
                }
        }
    }
}

// MARK: - Sidebar

@MainActor
private struct SidebarView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var engine = LeapinEngine.shared
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                .padding(.horizontal, compact ? 0 : 16)
                .padding(.top, 16)
                .padding(.bottom, compact ? 12 : 16)

            paletteEntry
                .padding(.horizontal, compact ? 10 : 12)
                .padding(.bottom, 16)

            // 分组导航放在可滚动区里：窗口高度不足时只压缩导航，引擎那一行始终可见。
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // 3 组 11 行全部来自 WorkbenchSidebar（T-05 的纯数据）：顺序、分组、
                    // 落点和 ⌘1..⌘4 都由那份计划决定，侧栏只负责画和把行变成动作。
                    ForEach(Array(WorkbenchSidebar.groups.enumerated()), id: \.element.id) { groupIndex, group in
                        if groupIndex > 0 {
                            if compact {
                                Rectangle().fill(LP.line).frame(height: 1)
                                    .padding(.horizontal, 16).padding(.vertical, 6)
                            } else {
                                LPLabel(group.name)
                                    .padding(.horizontal, 18)
                                    .padding(.top, 16)
                                    .padding(.bottom, 6)
                            }
                        } else if !compact {
                            LPLabel(group.name)
                                .padding(.horizontal, 18)
                                .padding(.bottom, 6)
                        }

                        VStack(spacing: 2) {
                            ForEach(group.rows) { row in
                                SidebarRow(title: row.title,
                                           icon: row.icon,
                                           selected: isSelected(row),
                                           hint: row.shortcut,
                                           compact: compact) {
                                    app.dispatch(row.destination)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.bottom, 6)
            }

            EngineLine(compact: compact)
                .padding(.horizontal, compact ? 8 : 12)
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Rectangle().fill(LP.line).frame(height: 1) }
        }
        .padding(.vertical, 6)
        .frame(width: compact ? LPShell.sidebarCompact : LPShell.sidebarWidth)
        .lpSheet(radius: 20)
        // 侧栏是搁在纸面上的一张卡：一圈很淡的投影把它和窗口分开，不用再加一道粗边。
        .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
    }

    /// 选中态只认 section 行：sheet 与导入是动作、不是页面，永远不选中。
    /// `.why` 与 `.capture` 是同一个页面的两个 rawValue，任一成立都算「为什么」选中。
    private func isSelected(_ row: WorkbenchSidebar.Row) -> Bool {
        guard case .section(let raw) = row.destination,
              let target = AppModel.Section(rawValue: raw) else { return false }
        if target == .why || target == .capture {
            return app.section == .why || app.section == .capture
        }
        return app.section == target
    }

    private var paletteEntry: some View {
        Button {
            app.showPalette = true
        } label: {
            if compact {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LP.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .lpSheet(radius: LPRadius.control)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LP.textTertiary)
                    // 与「前往」菜单、菜单栏面板同一个词：同一个东西不在三处叫三个名字。
                    Text("命令面板")
                        .font(.system(size: 13))
                        .foregroundStyle(LP.textSecondary)
                    Spacer(minLength: 4)
                    LPKeyCap(keys: "⌘K")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .lpSheet(radius: LPRadius.control)
            }
        }
        .buttonStyle(.plain)
        .help("打开命令面板（⌘K）")
        .accessibilityLabel("打开命令面板")
    }

    /// 字标旁边的标记与 App 图标是同一个母题（一条路：两个端点、一个朱红点），
    /// 不是另一枚临时的字母块。口号用一句衬线：全 App 只有这里用它。
    private var brand: some View {
        HStack(spacing: 9) {
            LPMark(size: 26)
            if !compact {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Leapin")
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(LP.text)
                    Text("One leap. No detour.")
                        .font(LPType.quote)
                        .foregroundStyle(LP.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Leapin")
    }
}

@MainActor
private struct SidebarRow: View {
    let title: String
    let icon: String
    let selected: Bool
    var hint: String? = nil
    var compact: Bool = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? LP.accent : LP.textSecondary)
                if !compact {
                    Text(title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? LP.text : LP.textSecondary)
                    Spacer(minLength: 0)
                    if hover, let hint, !selected {
                        Text("⌘\(hint)")
                            .font(LPFont.mono(11))
                            .foregroundStyle(LP.textTertiary)
                    }
                }
            }
            .padding(.horizontal, compact ? 0 : 10)
            .padding(.vertical, compact ? 8 : 6)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .background(
                RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
                    .fill(selected ? LP.selectionFill : (hover ? LP.hover : Color.clear))
            )
            .overlay(alignment: .leading) {
                // 紧凑栏里图标居中，左侧胶囊会压到图标；选中态由底色和强调色图标表达。
                if selected, !compact {
                    Capsule()
                        .fill(LP.accent)
                        .frame(width: 2, height: 14)
                        .offset(x: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(hint.map { "\(title)（⌘\($0)）" } ?? title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 侧栏脚注：本地服务自己开没开、听在哪个端口。
///
/// 它不是第二个「接管」开关——接管只有页头那一枚。这里只管服务本身，给手动配置
/// 代理的 App（终端、浏览器）留一个不惊动系统代理的启停，所以它小、且只有一行。
@MainActor
private struct EngineLine: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var engine = LeapinEngine.shared
    var compact: Bool = false

    var body: some View {
        if compact {
            VStack(spacing: 8) {
                StatusDot(color: stateColor, pulsing: engine.state == .running)
                engineButton
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    StatusDot(color: stateColor, pulsing: engine.state == .running)
                    Text(engine.state.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LP.text)
                    Spacer(minLength: 4)
                    engineButton
                }
                // 端口不是数量：用 String() 拼接，别让插值给它加千分位（7,892）。
                Text("混合 " + String(engine.profile.general.mixedPort)
                     + " · DNS " + String(engine.profile.dns.listenPort))
                    .font(LPFont.mono(11))
                    .foregroundStyle(LP.textTertiary)
                    .lineLimit(1)
                    .padding(.leading, 18)
            }
        }
    }

    private var engineButton: some View {
        Button {
            app.toggle()
        } label: {
            Image(systemName: engine.state == .running ? "stop.fill" : "play.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(engine.state == .running ? LP.danger : LP.accent)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(engine.state == .running
              ? "停止本地服务；如果已经接管，系统代理会同时恢复"
              : "只启动本地服务，不接入系统代理。接管整个网络请用页头的「网络接管」")
        .accessibilityLabel(engine.state == .running ? "停止本地服务" : "启动本地服务")
    }

    private var stateColor: Color {
        switch engine.state {
        case .running: return LP.mint
        case .starting: return LP.amber
        case .failed: return LP.danger
        case .stopped: return LP.textTertiary
        }
    }
}

// MARK: - Page header

@MainActor
private struct PageHeaderBar: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var engine = LeapinEngine.shared
    var compact: Bool = false

    private var section: AppModel.Section { app.section ?? .dashboard }

    /// 页头：标题块 + 当前页的 tab + 全局主开关，一条底线。
    ///
    /// tab 住在页头里而不是页头下面：四个动词页于是从同一行开始画内容，
    /// tab 也不可能再和筛选 chip 混成一种东西。
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 标题用动词名：dashboard → 走哪、capture/why → 为什么。落到哪个页就写哪个动词，
            // 否则页头会拿旧页名（网络活动 / 排障与配置）盖在动词页上。
            titleBlock
            if let tabs = app.headerTabs {
                LPTabBar(items: tabs.items,
                         selected: tabs.selected,
                         underlineDrop: Self.underlineDrop) { id in tabs.onSelect(id) }
                    .padding(.leading, 24)
            }
            Spacer(minLength: 16)
            takeover
        }
        .padding(.horizontal, LPSpace.inset)
        .padding(.top, LPShell.headerTop)
        .frame(height: LPShell.headerHeight, alignment: .top)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LP.line).frame(height: 1)
        }
    }

    /// 文字框底边到页头底线的距离：下划线靠它正好落在那条线上。
    private static var underlineDrop: CGFloat {
        LPShell.headerHeight - 1 - LPShell.headerTop - LPShell.titleLine
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.headerTitle)
                .font(LPType.title)
                .tracking(-0.3)
                .foregroundStyle(LP.text)
                .lineLimit(1)
                .fixedSize()
            Text(section.headerSubtitle)
                .font(.system(size: 12))
                .foregroundStyle(LP.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // 四个动词名二到四个字不等；给标题块一个共同的最小宽，tab 的起点才在每页都对齐。
        .frame(minWidth: compact ? 0 : 96, alignment: .leading)
    }

    /// 全局唯一的主开关：系统流量有没有交给 Leapin。
    ///
    /// 这一枚胶囊把「状态」和「开关」并在一起——以前页头一个状态胶囊、侧栏一张状态卡、
    /// 焦点带一句「已停止」，同一屏把同一件事说三遍，还各带一个启停入口。
    private var takeover: some View {
        let on = engine.systemProxyActive
        let busy = app.networkBusy || engine.configurationBusy || engine.state == .starting
        return HStack(spacing: 8) {
            StatusDot(color: takeoverColor, pulsing: on)
            if !compact {
                Text(takeoverLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(on ? LP.text : LP.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            LPSwitch(isOn: Binding(
                get: { on },
                set: { enabled in
                    if enabled { app.connectNetwork() } else { Task { await app.pauseNetwork() } }
                }
            ), width: 32)
            .disabled(busy)
        }
        .padding(.leading, 12)
        .padding(.trailing, compact ? 8 : 10)
        .frame(height: 32)
        .background(Capsule(style: .continuous).fill(LP.sheet))
        .overlay(Capsule(style: .continuous).strokeBorder(LP.line, lineWidth: 1))
        .help(on ? "系统代理正指向 Leapin；关掉后恢复原设置"
                 : "把系统代理指向 Leapin（会先启动本地服务）")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("网络接管")
        .accessibilityValue(on ? "已接管" : "未接管")
    }

    /// 关着时叫它本名，让人知道这个开关管什么；开着时才说状态。
    private var takeoverLabel: String {
        if app.networkBusy { return "接管中…" }
        return engine.systemProxyActive ? "已接管" : "网络接管"
    }

    private var takeoverColor: Color {
        if app.networkBusy || engine.state == .starting { return LP.amber }
        if case .failed = engine.state { return LP.danger }
        return engine.systemProxyActive ? LP.mint : LP.textTertiary
    }
}

struct StatusChip: View {
    let state: EngineState
    var plain: Bool = false

    var body: some View {
        Group {
            if plain {
                label
            } else {
                label
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .lpPill()
            }
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            StatusDot(color: color, pulsing: state == .running)
            Text(state.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LP.textSecondary)
        }
    }

    private var color: Color {
        switch state {
        case .running: return LP.mint
        case .starting: return LP.amber
        case .failed: return LP.danger
        case .stopped: return LP.textTertiary
        }
    }
}

struct StatusPill: View {
    let state: EngineState
    var body: some View { StatusChip(state: state) }
}


/// The status-bar item: shield plus the last measured latency, so the number is
/// visible with the panel closed.
///
/// 字形由 `ResidentTone` 决定（T-02），不再看“跑没跑”这一个布尔：降级与失败
/// 都还在 running 里，只问 running 的话这两种状态会被画成同一枚盾。
///
/// 为什么图标自己推一次：`ResidentStatusStore` 的帧以前只由面板（打开时）和浮窗
/// （可见时）喂，窗口全关时它停在 `.empty`，状态栏就永远是 idle——S5 承诺的
/// “关着窗出问题，菜单栏变红”于是永远不成立。这里改成事件驱动：只订阅引擎里
/// **低频**的那几个信号（状态 / 系统代理 / 错误 / 配置），到一次推一次。
/// 不订阅 `$stats`：它每个请求都变，状态栏会跟着抖；也不加任何定时器。
@MainActor
private struct MenuBarLabel: View {
    /// 用 `let` 而不是 `@ObservedObject`：引擎的每一个 `@Published`（包括每请求都变的
    /// `stats`）都会让订阅它的视图重绘，状态栏图标就会被每个请求重画一次。
    /// 这里只靠下面几条 `onReceive` 显式订阅低频信号，够了。
    private let engine = LeapinEngine.shared
    /// 徽标（延迟）要跟着测速更新，这一个仍然观察。
    @ObservedObject private var status = MenuBarStatus.shared
    /// 图标自己记的 tone：store 可能还没人喂过，不能直接读它的瞬时值当真相。
    @State private var tone: ResidentTone = .idle
    /// v6：图标右侧两条 2.5pt 微条。1 Hz 采样，不跟着每个请求重画。
    @State private var downRate: Double = 0
    @State private var upRate: Double = 0
    private static let meterTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        icon
            // 首帧没有旧值问题，直接推。
            .onAppear { sync() }
            // 其余一律延后一拍：`@Published` 在 willSet 发值，同步回调里读到的还是旧属性，
            // 不延后的话启动后图标停在 idle、停止后停在 normal，之后没人纠正。
            .onReceive(engine.$state) { _ in scheduleSync() }
            .onReceive(engine.$systemProxyActive) { _ in scheduleSync() }
            .onReceive(engine.$lastError) { _ in scheduleSync() }
            .onReceive(engine.$profile) { _ in scheduleSync() }
            // 微条只读「此刻的速率」，一秒一帧；面板打开时 store 也在喂，Meter 自己会去重。
            .onReceive(Self.meterTicker) { _ in sampleRates() }
    }

    private func sampleRates() {
        let fresh = ResidentStatusStore.shared.update(from: engine)
        downRate = fresh.rates.down
        upRate = fresh.rates.up
    }

    @ViewBuilder private var icon: some View {
        HStack(spacing: 3) {
            if let badge = status.badge, tone == .normal {
                // 延迟只在正常态出现：降级/失败时挂着旧延迟，等于用旧数字冒充健康。
                Label(badge, systemImage: tone.iconName)
                    .accessibilityLabel(tone.accessibilityText)
            } else {
                Image(systemName: tone.iconName)
                    .accessibilityLabel(tone.accessibilityText)
            }
            if engine.state == .running {
                MenuBarMeter(down: downRate, up: upRate)
            }
        }
    }

    /// 事件到了才推一帧；`update(from:)` 是 store 的既有入口，这里不改 store。
    /// 不持有 store 引用：渲染不读它，写一次就走。
    private func sync() {
        tone = ResidentStatusStore.shared.update(from: engine).tone
    }

    /// 延后一拍再推：`@Published` 的 willSet 语义决定了同步回调里属性还没换新，
    /// 这一拍是读得到新值的唯一代价，比加定时器便宜得多。
    private func scheduleSync() {
        DispatchQueue.main.async { sync() }
    }
}

/// 菜单栏图标里的两条微条：上行 / 下行，按对数归一，最高 12pt。
/// 它属于图标，不参与 VoiceOver（读屏读 tone 的文字就够了）。
private struct MenuBarMeter: View {
    var down: Double
    var up: Double

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            bar(up)
            bar(down)
        }
        .frame(width: 9, height: 12)
        .accessibilityHidden(true)
    }

    private func bar(_ rate: Double) -> some View {
        let level = rate <= 0 ? 0 : min(1, log1p(rate) / log1p(3_000_000))
        return Capsule()
            .frame(width: 2.5, height: max(1.5, level * 12))
            .foregroundStyle(.primary)
    }
}
