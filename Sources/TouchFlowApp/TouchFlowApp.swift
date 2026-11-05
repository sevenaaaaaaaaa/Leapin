import SwiftUI
import AppKit
import TouchFlowRuntime
import TouchFlowCore
import TouchFlowIntegrations
import TouchFlowPolicy
import TouchFlowNet

@main
@MainActor
struct TouchFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel()

    var body: some Scene {
        Window("TouchFlow", id: "main") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 1040, minHeight: 700)
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
                Button("打开数据目录") {
                    NSWorkspace.shared.open(app.engine.store.root)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("安装 / 打开根证书") { app.installCA() }
                Button("复制代理地址") {
                    TFClipboard.copy("127.0.0.1:\(app.engine.profile.general.mixedPort)")
                    app.showToast("已复制 127.0.0.1:\(app.engine.profile.general.mixedPort)", kind: .success)
                }
                Divider()
                Button("重新显示上手引导") {
                    UserDefaults.standard.set(false, forKey: "tf.onboarded")
                    app.showOnboarding = true
                }
            }

            CommandMenu("前往") {
                Button("命令面板…") { app.showPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("搜索当前页面") { app.requestSearchFocus() }
                    .keyboardShortcut("f", modifiers: .command)
                Divider()
                ForEach(Array(AppModel.Section.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { app.go(to: section) }
                        .keyboardShortcut(Self.key(for: index), modifiers: .command)
                }
                Divider()
                Button("启动 / 停止代理") { app.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button(app.engine.systemProxyActive ? "关闭系统代理" : "开启系统代理") {
                    app.engine.toggleSystemProxy(!app.engine.systemProxyActive)
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(app)
        } label: {
            Image(systemName: app.engine.state == .running ? "shield.lefthalf.filled" : "shield.slash")
        }
    }

    private static func key(for index: Int) -> KeyEquivalent {
        switch index {
        case 0: return "1"
        case 1: return "2"
        case 2: return "3"
        case 3: return "4"
        case 4: return "5"
        case 5: return "6"
        case 6: return "7"
        case 7: return "8"
        case 8: return "9"
        default: return "0"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case dashboard, rules, adblock, capture, ssh, nas, learn, privacy, profiles, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dashboard: return "总览"
            case .rules: return "分流规则"
            case .adblock: return "去广告"
            case .capture: return "抓包"
            case .ssh: return "SSH"
            case .nas: return "NAS"
            case .learn: return "智能学习"
            case .privacy: return "隐私"
            case .profiles: return "配置"
            case .settings: return "设置"
            }
        }
        var icon: String {
            switch self {
            case .dashboard: return "gauge.with.dots.needle.67percent"
            case .rules: return "arrow.triangle.branch"
            case .adblock: return "hand.raised.fill"
            case .capture: return "waveform.path.ecg"
            case .ssh: return "terminal"
            case .nas: return "externaldrive.connected.to.line.below"
            case .learn: return "brain"
            case .privacy: return "lock.shield"
            case .profiles: return "doc.on.doc"
            case .settings: return "gearshape"
            }
        }
        /// 该页面是否真的有可聚焦的搜索框（⌘F 只在 true 的页面上生效）。
        var supportsSearch: Bool {
            switch self {
            case .dashboard, .rules, .capture, .adblock, .profiles: return true
            case .ssh, .nas, .learn, .privacy, .settings: return false
            }
        }

        var subtitle: String {
            switch self {
            case .dashboard: return "实时状态、端点与分流解释"
            case .rules: return "Clash / Surge 规则、策略组与规则集"
            case .adblock: return "过滤列表、拦截统计与白名单"
            case .capture: return "HTTP(S) 请求抓取与 HAR 导出"
            case .ssh: return "交互式终端，密码经 askpass 传递"
            case .nas: return "Bonjour 发现与 SMB 挂载"
            case .learn: return "从 App 列表或截图生成分流规则"
            case .privacy: return "隐私审计与网络加固建议"
            case .profiles: return "配置导入、导出与切换"
            case .settings: return "端口、DNS、抓包与日志"
            }
        }
    }

    let engine = TouchFlowEngine.shared

    @Published var section: Section? = .dashboard
    @Published var toast: String?
    @Published var toastKind: TFToastKind = .success
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

    init() {
        if let raw = UserDefaults.standard.string(forKey: "startSection"),
           let s = Section(rawValue: raw) {
            section = s
            startSectionPref = s
        }
        launchAtLogin = LaunchAtLogin.isEnabled
        autostartProxy = ProcessInfo.processInfo.environment["TF_AUTOSTART"] == "1"
            || UserDefaults.standard.bool(forKey: "autostartProxy")
        engine.refreshSystemProxyStatus()
        if !UserDefaults.standard.bool(forKey: "tf.onboarded") {
            showOnboarding = true
        }
    }

    var isRunning: Bool { engine.state == .running }

    // MARK: Feedback

    func showToast(_ text: String,
                   kind: TFToastKind = .success,
                   actionTitle: String? = nil,
                   action: (() -> Void)? = nil) {
        toastKind = kind
        toastActionTitle = actionTitle
        toastAction = action
        toast = text
    }

    // MARK: Navigation

    func go(to section: Section) {
        withAnimation(.easeOut(duration: 0.12)) { self.section = section }
        UserDefaults.standard.set(section.rawValue, forKey: "startSection")
    }

    /// ⌘F 只对真正有搜索框的页面生效；其余页面改为打开命令面板，
    /// 避免「按了没反应」的假入口。
    func requestSearchFocus() {
        let page = section ?? .dashboard
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

    /// touchflow://section/rules, touchflow://toggle, touchflow://palette, touchflow://proxy/on
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "touchflow" else { return }
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
            engine.toggleSystemProxy(on)
        case "capture":
            go(to: .capture)
        default:
            if let target = Section(rawValue: head) { go(to: target) }
        }
    }

    // MARK: Actions

    func toggle() {
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

    func importProfile(url: URL) {
        Task {
            do {
                let outcome = try await engine.importProfileDetailed(from: url)
                importReport = outcome.report
                let report = outcome.report
                let blocking = report.issues.contains { $0.kind.isBlocking }
                if report.isClean {
                    showToast("已导入并启用 \(outcome.profile.name)（\(report.ruleCount) 条规则）",
                              kind: .success, actionTitle: "查看报告") { self.showImportReport = true }
                } else {
                    showToast(report.summary,
                              kind: blocking ? .error : .warning,
                              actionTitle: "查看报告") { self.showImportReport = true }
                }
            } catch {
                showToast("导入失败：\(error.localizedDescription)", kind: .error)
            }
        }
    }

    /// 从剪贴板里的订阅链接导入（机场订阅是最常见的入口，不该逼用户先存文件）。
    func importFromClipboardLink() {
        let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") else {
            showToast("剪贴板里没有 http(s) 订阅链接", kind: .warning)
            return
        }
        Task {
            showToast("正在下载订阅…", kind: .info)
            do {
                let outcome = try await engine.importRemoteProfile(raw)
                importReport = outcome.report
                let report = outcome.report
                let blocking = report.issues.contains { $0.kind.isBlocking }
                if report.isClean {
                    showToast("已导入订阅 \(outcome.profile.name)（\(report.ruleCount) 条规则）",
                              kind: .success, actionTitle: "查看报告") { self.showImportReport = true }
                } else {
                    showToast(report.summary, kind: blocking ? .error : .warning,
                              actionTitle: "查看报告") { self.showImportReport = true }
                }
            } catch {
                showToast(error.localizedDescription, kind: .error)
            }
        }
    }

    func exportProfile(format: ProfileFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "touchflow-\(format.cliName).\(format.fileExtension)"
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try engine.exportProfile(format)
            try text.write(to: url, atomically: true, encoding: .utf8)
            let name = url.lastPathComponent
            showToast("已导出到 \(name)", kind: .success, actionTitle: "在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            showToast("导出失败：\(error.localizedDescription)", kind: .error)
        }
    }

    func installCA() {
        let caURL = engine.store.root.appendingPathComponent("ca/touchflow-ca.pem")
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
    @ObservedObject private var engine = TouchFlowEngine.shared

    var body: some View {
        ZStack {
            TFBackground()
            HStack(spacing: 0) {
                SidebarView()
                Rectangle().fill(TF.stroke).frame(width: 1)
                VStack(spacing: 0) {
                    PageHeaderBar()
                    Rectangle().fill(TF.stroke).frame(height: 1)
                    sectionContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(WindowAutosave())
        .overlay(alignment: .bottom) { toastView }
        .overlay {
            if app.showPalette {
                CommandPalette()
                    .environmentObject(app)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.14), value: app.showPalette)
        .sheet(isPresented: $app.showOnboarding) {
            OnboardingView().environmentObject(app)
        }
        .sheet(isPresented: $app.showImportReport) {
            if let report = app.importReport {
                ImportReportSheet(report: report) { app.showImportReport = false }
            }
        }
        .preferredColorScheme(ProcessInfo.processInfo.environment["TF_APPEARANCE"] == "dark" ? .dark : nil)
        .task {
            if app.autostartProxy, engine.state != .running {
                await engine.start()
            }
        }
        .onOpenURL { app.handle(url: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .tfNavigate)) { note in
            if let raw = note.object as? String, let section = AppModel.Section(rawValue: raw) {
                app.go(to: section)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tfTogglePalette)) { _ in
            app.showPalette.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tfSearchFocus)) { _ in
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

    @ViewBuilder private var sectionContent: some View {
        switch app.section ?? .dashboard {
        case .dashboard: DashboardView()
        case .rules: RulesView()
        case .adblock: AdBlockView()
        case .capture: CaptureView()
        case .ssh: SSHView()
        case .nas: NASView()
        case .learn: LearnView()
        case .privacy: PrivacyView()
        case .profiles: ProfilesView()
        case .settings: SettingsView()
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
                    withAnimation(.easeOut(duration: 0.2)) {
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
    @ObservedObject private var engine = TouchFlowEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand.padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 14)

            paletteEntry
                .padding(.horizontal, 12)
                .padding(.bottom, 16)

            Text("工作区")
                .font(TFFont.overline)
                .tracking(1.1)
                .foregroundStyle(TF.textTertiary)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)

            VStack(spacing: 2) {
                ForEach(Array(AppModel.Section.allCases.enumerated()), id: \.element) { index, section in
                    SidebarRow(section: section,
                               selected: app.section == section,
                               hint: index < 9 ? "\(index + 1)" : "0") {
                        app.go(to: section)
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 8)
            StatusCard().padding(10)
        }
        .frame(width: 212)
        .background(.ultraThinMaterial.opacity(0.55))
    }

    private var paletteEntry: some View {
        Button {
            app.showPalette = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TF.textTertiary)
                Text("搜索或跳转")
                    .font(.system(size: 11))
                    .foregroundStyle(TF.textTertiary)
                Spacer(minLength: 4)
                TFKeyCap(keys: "⌘K")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(TF.stroke.opacity(0.4), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(TF.stroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开命令面板（⌘K）")
        .accessibilityLabel("打开命令面板")
    }

    private var brand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(TF.brand)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            .shadow(color: TF.accent.opacity(0.35), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 0) {
                Text("TouchFlow")
                    .font(TFFont.display(14.5, weight: .bold))
                    .foregroundStyle(TF.text)
                Text("NETWORK CONTROL")
                    .font(TFFont.mono(7.5, weight: .medium))
                    .tracking(1.0)
                    .foregroundStyle(TF.textTertiary)
            }
        }
    }
}

@MainActor
private struct SidebarRow: View {
    let section: AppModel.Section
    let selected: Bool
    var hint: String? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? TF.accent : TF.textSecondary)
                Text(section.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? TF.text : TF.textSecondary)
                Spacer(minLength: 0)
                if hover, let hint, !selected {
                    Text("⌘\(hint)")
                        .font(TFFont.mono(8.5))
                        .foregroundStyle(TF.textTertiary)
                } else if selected {
                    Circle().fill(TF.accent).frame(width: 4, height: 4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? TF.accentSoft : (hover ? TF.stroke.opacity(0.6) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(section.title)（⌘\(hint ?? "")）")
    }
}

@MainActor
private struct StatusCard: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var engine = TouchFlowEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                StatusDot(color: stateColor, pulsing: engine.state == .running)
                Text(engine.state.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(TF.text)
                Spacer(minLength: 0)
            }

            VStack(spacing: 4) {
                portRow("混合", engine.profile.general.mixedPort)
                portRow("DNS", engine.profile.dns.listenPort)
            }

            Button {
                app.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: engine.state == .running ? "stop.fill" : "play.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text(engine.state == .running ? "停止代理" : "启动代理")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TFPrimaryButtonStyle(tint: engine.state == .running ? TF.danger : nil))
        }
        .padding(12)
        .background(TF.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(TF.stroke))
    }

    private func portRow(_ label: String, _ port: UInt16) -> some View {
        HStack {
            Text(label).font(.system(size: 10)).foregroundStyle(TF.textTertiary)
            Spacer()
            Text(":" + String(port)).font(TFFont.mono(10, weight: .medium)).foregroundStyle(TF.textSecondary)
        }
    }

    private var stateColor: Color {
        switch engine.state {
        case .running: return TF.mint
        case .starting: return TF.amber
        case .failed: return TF.danger
        case .stopped: return TF.textTertiary
        }
    }
}

// MARK: - Page header

@MainActor
private struct PageHeaderBar: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var engine = TouchFlowEngine.shared

    private var section: AppModel.Section { app.section ?? .dashboard }

    var body: some View {
        PageHeader(title: section.title, subtitle: section.subtitle, icon: section.icon) {
            HStack(spacing: 10) {
                Button {
                    app.showPalette = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "command").font(.system(size: 9, weight: .semibold))
                        Text("⌘K").font(TFFont.mono(10, weight: .medium))
                    }
                    .foregroundStyle(TF.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(TF.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(TF.stroke))
                .help("命令面板（⌘K）")

                HStack(spacing: 7) {
                    Text("系统代理")
                        .font(.system(size: 11))
                        .foregroundStyle(TF.textSecondary)
                    TFSwitch(isOn: Binding(
                        get: { engine.systemProxyActive },
                        set: { engine.toggleSystemProxy($0) }
                    ), width: 32)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(TF.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(TF.stroke))

                StatusChip(state: engine.state)
            }
        }
    }
}

struct StatusChip: View {
    let state: EngineState

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: color, pulsing: state == .running)
            Text(state.label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(TF.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(TF.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(TF.stroke))
    }

    private var color: Color {
        switch state {
        case .running: return TF.mint
        case .starting: return TF.amber
        case .failed: return TF.danger
        case .stopped: return TF.textTertiary
        }
    }
}

struct StatusPill: View {
    let state: EngineState
    var body: some View { StatusChip(state: state) }
}

// MARK: - Menu bar

@MainActor
struct MenuBarPanel: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(TFFont.num(11, weight: .semibold)).foregroundStyle(TF.text)
            Text(label).font(.system(size: 8.5)).foregroundStyle(TF.textTertiary)
        }
    }

    var body: some View {
        let engine = app.engine
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(TF.brand)
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text("TouchFlow").font(TFFont.display(12.5, weight: .bold))
                    Text(engine.state.label).font(.system(size: 9.5)).foregroundStyle(TF.textTertiary)
                }
                Spacer()
                StatusDot(color: engine.state == .running ? TF.mint : TF.textTertiary,
                          pulsing: engine.state == .running)
            }

            Button {
                app.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: engine.state == .running ? "stop.fill" : "play.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text(engine.state == .running ? "停止代理" : "启动代理")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TFPrimaryButtonStyle(tint: engine.state == .running ? TF.danger : nil))

            HStack(spacing: 8) {
                Text("系统代理").font(.system(size: 11))
                Spacer()
                TFSwitch(isOn: Binding(
                    get: { engine.systemProxyActive },
                    set: { engine.toggleSystemProxy($0) }
                ), width: 30)
            }

            HStack(spacing: 10) {
                metric("连接", "\(engine.activeConnections)")
                metric("请求", "\(engine.stats.requests)")
                metric("拦截", "\(engine.stats.blocked)")
                Spacer()
                metric("流量", Fmt.bytes(engine.stats.bytesIn + engine.stats.bytesOut))
            }

            Button {
                TFClipboard.copy("127.0.0.1:\(engine.profile.general.mixedPort)")
                app.showToast("已复制代理地址")
            } label: {
                HStack(spacing: 5) {
                    Text("127.0.0.1:\(engine.profile.general.mixedPort)")
                        .font(TFFont.mono(9.5, weight: .medium))
                    Image(systemName: "doc.on.doc").font(.system(size: 8))
                }
                .foregroundStyle(TF.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("复制代理地址")

            TFDivider()

            VStack(spacing: 1) {
                ForEach([AppModel.Section.dashboard, .rules, .capture, .settings]) { section in
                    Button {
                        app.go(to: section)
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: section.icon).font(.system(size: 9.5)).frame(width: 14)
                            Text(section.title).font(.system(size: 11))
                            Spacer()
                        }
                        .foregroundStyle(TF.textSecondary)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            TFDivider()

            Button {
                app.showPalette = true
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack(spacing: 5) {
                    Text("命令面板").font(.system(size: 11))
                    Spacer()
                    TFKeyCap(keys: "⌘K")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button("打开主窗口") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))

            Button("退出 TouchFlow") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(TF.textSecondary)
        }
        .padding(14)
        .frame(width: 236)
    }
}
