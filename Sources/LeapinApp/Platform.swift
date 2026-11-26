import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import LeapinRuntime

extension Notification.Name {
    static let lpNavigate = Notification.Name("lp.navigate")
    static let lpTogglePalette = Notification.Name("lp.palette.toggle")
    static let lpSearchFocus = Notification.Name("lp.search.focus")
}

/// Debug 快照模式（`LEAPIN_SHOT`）。正式构建里恒为 false。
///
/// 处在这个模式时，窗口从头到尾待在屏幕外，App 也不抢前台：拍一张截图不该在别人
/// 屏幕上闪一个窗口、再把键盘焦点夺走。
enum LPShooting {
    static var isOn: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LEAPIN_SHOT"] != nil
        #else
        return false
        #endif
    }
}

/// 把 macOS 26 的玻璃页头背景藏进纸里：标题栏区域只留红黄绿三个按钮，
/// 底下就是连续的纸面，不再有一条浅色带横在窗口顶上。
private struct LPHeaderBlend: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

extension View {
    func headerBlended() -> some View { modifier(LPHeaderBlend()) }
}

/// 把窗口标题栏彻底压平：SwiftUI 一改窗口标题（哪怕只是页面名）就会把
/// `titleVisibility` 翻回 visible，顶上于是浮出一条带字的条——和侧栏的品牌名
/// 叠成两个「Leapin」。这里监听标题变化，每次都把可见性按回 hidden。
/// 红黄绿三个按钮照常，其余的标题栏区域是透明的纸/空间。
private final class LPTitleFlattener: NSView {
    private var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window !== observedWindow else { return }
        observedWindow?.removeObserver(self, forKeyPath: "title")
        observedWindow = window
        window.titleVisibility = .hidden
        window.addObserver(self, forKeyPath: "title", options: [.new], context: nil)
        window.titleVisibility = .hidden
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "title", let window { window.titleVisibility = .hidden }
    }

    deinit {
        observedWindow?.removeObserver(self, forKeyPath: "title")
    }
}

/// Keeps window size/position across launches without a storyboard.
struct WindowAutosave: NSViewRepresentable {
    var name: String = "LeapinMain"

    func makeNSView(context: Context) -> NSView {
        let view = LPTitleFlattener()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if LPShooting.isOn {
                // 快照也挂自动保存（尺寸才会被 SwiftUI 采纳），随后把窗口挪到屏幕外。
                // 屏幕外的位置会被记进 defaults，但 shoot.sh / live.sh 每次运行前都重写
                // 这份尺寸，所以不影响下一次。
                window.setFrameAutosaveName(name)
                window.minSize = NSSize(width: 900, height: 640)
                window.setFrame(from: name)
                window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            } else {
                window.setFrameAutosaveName(name)
                window.minSize = NSSize(width: 900, height: 640)
                // 上次的显示器可能已断开：窗口不在任何可见屏幕内时回到主屏中央。
                if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
                    window.center()
                    window.saveFrame(usingName: name)
                }
            }
            // 标题栏并入纸面：标题栏透明、不画字、不画底下的分隔线（页头自己有一条）。
            // 灰带的真正来源是页面的 `.navigationTitle`：SwiftUI 一看到页面标题就把标题栏
            // 连字带底重新显示出来，全 App 因此不再设它（页头已经写着页面名）。
            // fullSizeContentView 本来就是开的，这里保留是防它将来被谁拿掉。
            window.styleMask.insert(.fullSizeContentView)
            // macOS 26 的系统页头是玻璃材质：不显式隐藏背景的话，它会在纸面上方
            // 压出一条突兀的浅色带。SwiftUI 侧再配合 toolbarBackgroundVisibility。
            window.toolbar = nil
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            // 一张纸就是一张纸。窗口以前是桌面模糊之上的 40% 纸色洗色，可读性于是取决于
            // 壁纸：深色壁纸把「纸」洗成浑浊的灰褐，发丝线全部消失。现在窗口不透明，
            // 纸色由 LPBackground 铺满；玻璃只留给浮层。
            window.isOpaque = true
            window.backgroundColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 15 / 255, green: 15 / 255, blue: 16 / 255, alpha: 1)
                    : NSColor(srgbRed: 244 / 255, green: 239 / 255, blue: 230 / 255, alpha: 1)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Global ⌘⇧Space hotkey so the palette works from any app.
@MainActor
final class GlobalHotKeyCenter {
    static let shared = GlobalHotKeyCenter()
    var onFire: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registered = false

    func register() {
        guard !registered else { return }
        registered = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<GlobalHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { center.onFire?() }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x54464C57), id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

/// App-level lifecycle: hotkey, dock menu, and never leaving the system proxy behind on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var stopExternalTools: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 快照模式不抢前台：不上 Dock、不被激活，窗口也一直在屏幕外。
        if LPShooting.isOn {
            NSApp.setActivationPolicy(.accessory)
        }
        // 让标题栏跟随内容主题，避免深色内容配浅色窗框。
        if ProcessInfo.processInfo.environment["LEAPIN_APPEARANCE"] == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if ProcessInfo.processInfo.environment["LEAPIN_APPEARANCE"] == "light" {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        GlobalHotKeyCenter.shared.onFire = {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .lpTogglePalette, object: nil)
        }
        GlobalHotKeyCenter.shared.register()

        // The panel is the only surface that stays visible while the main window is
        // closed, so it comes back on launch if the user left it on.
        FloatingPanelController.shared.restoreIfNeeded()

        #if DEBUG
        if let spec = ProcessInfo.processInfo.environment["LEAPIN_SNAPSHOT_VIEW"],
           let path = ProcessInfo.processInfo.environment["LEAPIN_SNAPSHOT_PATH"] {
            // LEAPIN_SNAPSHOT_ENGINE=1：先把引擎跑起来再拍（只配合隔离的 LEAPIN_PROFILE_ROOT），
            // 菜单栏面板这类常驻面于是有了「运行中」的截图。
            // LEAPIN_SNAPSHOT_WAIT=秒数：落定之前多留一段窗口，给外部往代理里灌流量。
            let startEngine = ProcessInfo.processInfo.environment["LEAPIN_SNAPSHOT_ENGINE"] == "1"
            let settle = Double(ProcessInfo.processInfo.environment["LEAPIN_SNAPSHOT_WAIT"] ?? "") ?? 1.4
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                if startEngine { await LeapinEngine.shared.start() }
                if ProcessInfo.processInfo.environment["LEAPIN_SNAPSHOT_APPEARANCE"] == "light" {
                    NSApp.appearance = NSAppearance(named: .aqua)
                }
                let model = AppModel()
                let content: AnyView
                // 快照名跟着 M2 的新壳走（T-13）：同一个像素由哪个视图画，必须和 sectionContent 一致。
                // 退役页没有自己的快照名了——它们的名字现在指向落点所在的动词页那一页。
                switch spec {
                case "dashboard": content = AnyView(GoWherePage(initialTab: .overview).environmentObject(model))
                case "profiles": content = AnyView(GoWherePage(initialTab: .profiles).environmentObject(model))
                case "settings": content = AnyView(SettingsView().environmentObject(model))
                case "rules": content = AnyView(RulesView().environmentObject(model))
                case "capture", "why": content = AnyView(WhyPage(initialTab: .connections).environmentObject(model))
                case "activity": content = AnyView(WhyPage(initialTab: .metrics).environmentObject(model))
                case "diagnostics": content = AnyView(WhyPage(initialTab: .diagnostics).environmentObject(model))
                case "adblock": content = AnyView(RewriteView().environmentObject(model))
                case "rewrite": content = AnyView(RewriteView().environmentObject(model))
                case "learn": content = AnyView(LearnView().environmentObject(model))
                case "spine-detail":
                    content = AnyView(LPSpineDetailSheet(spine: lpSpineFixture(name: "机场主订阅", source: "机场主订阅.yaml",
                                                                              rules: 303, days: 3, broken: true),
                                                         isActive: true, busy: false,
                                                         onActivate: {}, onExport: { _ in },
                                                         onDelete: {}, onClose: {})
                        .frame(maxWidth: .infinity, maxHeight: .infinity))
                case "spine-compare":
                    content = AnyView(LPSpineCompareSheet(
                        comparison: LPSpineCompare.run(lpSpineFixture(name: "公司直连", source: "公司直连.yaml", rules: 11, days: 0),
                                                       lpSpineFixture(name: "机场主订阅", source: "机场主订阅.yaml", rules: 303, days: 3, broken: true)),
                        onClose: {})
                        .frame(maxWidth: .infinity, maxHeight: .infinity))
                case "spine-empty":
                    content = AnyView(LPSpineShelf(spines: [], activeID: nil,
                                                   actions: LPSpineShelfActions(pull: { _ in }, compare: { _, _ in },
                                                                                activate: { _ in }, export: { _, _ in },
                                                                                delete: { _ in }, importProfile: {})))
                // 菜单栏面板：常驻层是 99% 的接触面，却一直没法离屏拍。
                case "menubar":
                    content = AnyView(MenuBarPanel().environmentObject(model)
                        .fixedSize()
                        .padding(24))
                default: content = AnyView(Text("unknown view: \(spec)"))
                }
                let host = NSHostingView(rootView:
                    content
                        // WhyPage 在出现时从 RouteContext 取一次 host（T-07）。快照直接实例化视图，
                        // 没有根视图那层注入；缺这一行不是画错，是取 route 时运行时崩。
                        .environmentObject(model.routes)
                        .frame(width: 1160, height: 860)
                        // 纸色，不是系统的窗口灰：页面和面板在实际运行时都坐在纸上。
                        .background(LP.paper))
                host.frame = NSRect(x: 0, y: 0, width: 1160, height: 860)
                // Pages that size themselves from the window (settings' columns,
                // activity's chart) render blank in a bare hosting view, so give
                // the snapshot a real offscreen window to lay out inside.
                let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1160, height: 860),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                let appearance = ProcessInfo.processInfo.environment["LEAPIN_SNAPSHOT_DARK"] == "1"
                    ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
                window.appearance = appearance
                host.appearance = appearance
                window.contentView = host
                window.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                // LEAPIN_SNAPSHOT_POPUP=1：菜单栏面板的切换行弹的是 AppKit 菜单，快照里没有鼠标
                // 来点。于是真的弹一次、到点自动收起，确认建菜单 → 弹出 → 追踪 → 取消这一路不崩，
                // 且确实进了追踪（持续时间≈autoDismiss；一调用就返回说明菜单根本没弹出来）。
                // 菜单画在另一个窗口里，拍不进这张图；它会在这个窗口旁边闪一下，所以只在冒烟时开。
                if ProcessInfo.processInfo.environment["LEAPIN_SNAPSHOT_POPUP"] == "1" {
                    DispatchQueue.main.async {
                        let items: [LPPopUpItem] = [
                            .item("甲", selected: true) {},
                            .item("乙") {},
                            .submenu("组", [.item("丙") {}, .item("丁") {}]),
                            .separator,
                            .note("说明"),
                        ]
                        let tracked = LPPopUpMenu.show(items, below: host, autoDismiss: 0.8)
                        print("leapin-snapshot: popup tracked for \(String(format: "%.2f", tracked))s")
                    }
                }
                // 1.4s：书脊这类异步取数的块要等它落地，否则拍到的是淡入中途的一帧。
                try? await Task.sleep(for: .seconds(settle))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                window.orderOut(nil)
                NSApp.terminate(nil)
            }
        }
        // Debug: render the live window to a PNG without screen-recording permission.
        // LEAPIN_SHOT=/tmp/x.png LEAPIN_SHOT_SECTION=settings
        // LEAPIN_SHOT_ENGINE=1 先把引擎跑起来再拍，看到的是运行中的首屏，不是未接管的空态。
        // 只配合隔离的 LEAPIN_PROFILE_ROOT 使用；演示配置用私有端口、关掉控制面，
        // 所以它和正在使用的正式实例谁先谁后都互不影响。引擎自身从不改系统代理。
        // LEAPIN_SHOT_WAIT=秒数 在导航之后多留一段窗口，给外部往代理里灌流量。
        if let path = ProcessInfo.processInfo.environment["LEAPIN_SHOT"] {
            let section = ProcessInfo.processInfo.environment["LEAPIN_SHOT_SECTION"]
            let startEngine = ProcessInfo.processInfo.environment["LEAPIN_SHOT_ENGINE"] == "1"
            let wait = Double(ProcessInfo.processInfo.environment["LEAPIN_SHOT_WAIT"] ?? "") ?? 0
            Task { @MainActor in
                if startEngine { await LeapinEngine.shared.start() }
                try? await Task.sleep(for: .milliseconds(600))
                if let section { NotificationCenter.default.post(name: .lpNavigate, object: section) }
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                try? await Task.sleep(for: .seconds(2))
                // LEAPIN_SHOT_DEBUG=1：把此刻的窗口列出来。拍到一张全透明的图时，先看它拍的是不是
                // 期望的那个窗口。
                if ProcessInfo.processInfo.environment["LEAPIN_SHOT_DEBUG"] == "1" {
                    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
                    print("leapin-snapshot: active=\(NSApp.isActive) frontmost=\(front)")
                    for (index, open) in NSApp.windows.enumerated() {
                        let content = open.contentView.map { String(describing: type(of: $0)) } ?? "nil"
                        print("leapin-snapshot: window[\(index)] \(type(of: open)) visible=\(open.isVisible) key=\(open.isKeyWindow) frame=\(open.frame) content=\(content)")
                    }
                }
                guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.contentView != nil }) else {
                    NSApp.terminate(nil); return
                }
                // 快照模式里窗口没挂自动保存，SwiftUI 于是按默认尺寸开窗；这里补读保存的尺寸
                // 再挪回屏幕外，拍出来的才是想要的大小（AppKit 会自己留一个角在屏幕上）。
                if window.frameAutosaveName.isEmpty {
                    window.setFrame(from: "LeapinMain")
                    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                    try? await Task.sleep(for: .milliseconds(600))
                }
                let view = window.contentView!
                // LEAPIN_SHOT_CG=1：拍窗口服务器合成后的画面。系统原生控件（圆角输入框、密码框、
                // Form）在 macOS 26+ 是玻璃材质，任何离屏光栅化都拍不下来，只有这一条路看得到它们
                // 本来的样子。代价是窗口得回到屏幕上（主屏左上角）不到一秒；不激活 App，不抢焦点。
                if ProcessInfo.processInfo.environment["LEAPIN_SHOT_CG"] == "1" {
                    if let screen = NSScreen.main {
                        var frame = window.frame
                        frame.origin = NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - frame.height - 40)
                        window.setFrame(frame, display: true)
                        window.orderFrontRegardless()
                        try? await Task.sleep(for: .milliseconds(800))
                        if let shot = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                              CGWindowID(window.windowNumber),
                                                              [.boundsIgnoreFraming, .bestResolution]) {
                            let rep = NSBitmapImageRep(cgImage: shot)
                            try? rep.representation(using: .png, properties: [:])?
                                .write(to: URL(fileURLWithPath: path))
                        }
                    }
                    NSApp.terminate(nil)
                    return
                }
                // LEAPIN_SHOT_PDF=1：改走 PDF。`cacheDisplay` 拍不下系统原生控件（圆角输入框、密码框、
                // Form 在 macOS 26+ 是玻璃材质画的），含这些控件的页面会得到一张全透明的图；
                // 让视图把自己画进 PDF 再栅格化，这一类页面才有得看。
                if ProcessInfo.processInfo.environment["LEAPIN_SHOT_PDF"] == "1" {
                    let data = view.dataWithPDF(inside: view.bounds)
                    try? data.write(to: URL(fileURLWithPath: path + ".pdf"))
                }
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
        if let path = ProcessInfo.processInfo.environment["LEAPIN_SNAPSHOT_REWRITE"] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                let host = NSHostingView(rootView:
                    RewriteView().environmentObject(AppModel()).frame(width: 980, height: 640))
                host.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
                if let appearance = ProcessInfo.processInfo.environment["LEAPIN_SNAPSHOT_APPEARANCE"],
                   let resolved = NSAppearance(named: NSAppearance.Name(rawValue: appearance)) {
                    NSApp.appearance = resolved
                    host.appearance = resolved
                }
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: path))
                    }
                }
                NSApp.terminate(nil)
            }
        }
        if let path = ProcessInfo.processInfo.environment["LEAPIN_SNAPSHOT_PANEL"] {
            let autostart = ProcessInfo.processInfo.environment["LEAPIN_SNAPSHOT_ENGINE"] == "1"
            Task {
                if autostart { await LeapinEngine.shared.start() }
                try? await Task.sleep(for: .seconds(7))
                FloatingPanelController.shared.snapshot(to: path)
                NSApp.terminate(nil)
            }
        }
        // UI check for the Profiles node panel: boots the engine for real, opens the
        // 配置 page in the live window, waits until the node list carries at least one
        // probe result (the panel's auto-test landing), then captures the window's view
        // hierarchy — no screen-recording permission needed. Never in release.
        if let path = ProcessInfo.processInfo.environment["LEAPIN_SNAPSHOT_PROFILES"] {
            Task { @MainActor in
                let engine = LeapinEngine.shared
                if engine.state != .running { await engine.start() }
                var window: NSWindow?
                for _ in 0..<20 {
                    window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.contentView != nil })
                    if window != nil { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                NotificationCenter.default.post(name: .lpNavigate, object: AppModel.Section.profiles.rawValue)
                let deadline = Date().addingTimeInterval(40)
                while Date() < deadline {
                    let nodes = await engine.controlNodes()
                    // Every dialable node must carry a probe record — a single fast
                    // failure (e.g. a junk 0.0.0.0 entry) must not end the wait early.
                    let dialable = nodes.filter(\.dialable)
                    if !dialable.isEmpty, dialable.allSatisfy({ $0.checkedAtMs != nil }) { break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                try? await Task.sleep(for: .seconds(1))
                if let view = window?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: path))
                    }
                }
                NSApp.terminate(nil)
            }
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        let engine = LeapinEngine.shared
        engine.stop()
        engine.managedKernel.stop()
        stopExternalTools?()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let engine = LeapinEngine.shared
        let menu = NSMenu()

        let toggleTitle = engine.state == .running ? "停止代理" : "启动代理"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(dockToggleProxy), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let floatingTitle = FloatingPanelController.shared.isVisible ? "隐藏实时浮窗" : "显示实时浮窗"
        let floatingItem = NSMenuItem(title: floatingTitle, action: #selector(dockToggleFloating), keyEquivalent: "")
        floatingItem.target = self
        menu.addItem(floatingItem)

        let proxyItem = NSMenuItem(title: engine.systemProxyActive ? "关闭系统代理" : "开启系统代理",
                                   action: #selector(dockToggleSystemProxy), keyEquivalent: "")
        proxyItem.target = self
        menu.addItem(proxyItem)
        menu.addItem(.separator())

        // 四个动词 + 设置。标题用动词名（走哪 / 怎么判 / 为什么），落点和侧栏同一套；
        // `.capture` 只是 `.why` 的深链 alias，菜单里不再出现「抓包」这个名字。
        for section in [AppModel.Section.dashboard, .rules, .why, .settings] {
            let item = NSMenuItem(title: section.headerTitle, action: #selector(dockOpenSection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = section.rawValue
            menu.addItem(item)
        }
        return menu
    }

    @objc private func dockToggleProxy() {
        let engine = LeapinEngine.shared
        if engine.state == .running { engine.stop() }
        else { Task { await engine.start() } }
    }

    @objc private func dockToggleFloating() {
        FloatingPanelController.shared.toggle()
    }

    @objc private func dockToggleSystemProxy() {
        let engine = LeapinEngine.shared
        Task { await engine.toggleSystemProxy(!engine.systemProxyActive) }
    }

    @objc private func dockOpenSection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .lpNavigate, object: raw)
    }
}

// MARK: - Launch at login

/// 用 SMAppService 管理「登录时启动」。未打包运行（swift run）时 register 会失败，
/// 这里把错误如实交回调用方，让设置页用 toast 说明，而不是静默假装成功。
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已在登录时启动"
        case .requiresApproval: return "需要在系统设置 › 通用 › 登录项 中允许"
        case .notRegistered: return "登录时不启动"
        case .notFound: return "仅打包后的 App 支持"
        @unknown default: return "未知状态"
        }
    }

    /// nil = 成功；否则为展示给用户的失败原因。
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
#if DEBUG
/// 快照用的书脊样本：与 fixtures 里的四份配置同形，但不需要真的导入。
private func lpSpineFixture(name: String, source: String, rules: Int, days: Double,
                            broken: Bool = false) -> LPSpineSnapshot {
    let tallies: [LPSpineTally] = broken
        ? [LPSpineTally(name: "domain-suffix", count: 284), LPSpineTally(name: "ip-cidr", count: 9),
           LPSpineTally(name: "domain-keyword", count: 1), LPSpineTally(name: "geoip", count: 1),
           LPSpineTally(name: "match", count: 1)]
        : [LPSpineTally(name: "domain-suffix", count: 9), LPSpineTally(name: "ip-cidr", count: 2),
           LPSpineTally(name: "geoip", count: 0), LPSpineTally(name: "match", count: 1),
           LPSpineTally(name: "domain-keyword", count: 1)]
    return LPSpineSnapshot(
        id: UUID(),
        name: name,
        source: source,
        updatedAt: Date().addingTimeInterval(-days * 86_400),
        ruleCount: rules,
        ruleLines: (0..<rules).map { i in
            let kind = broken ? "DOMAIN-SUFFIX,cdn\(String(format: "%03d", i)).example.net → Proxy"
                              : "DOMAIN-SUFFIX,svc\(String(format: "%02d", i)).home.arpa → DIRECT"
            return kind
        },
        tallies: tallies,
        groups: broken
            ? [LPSpineGroup(name: "Proxy", type: "url-test", memberCount: 9),
               LPSpineGroup(name: "Fallback", type: "fallback", memberCount: 0)]
            : [LPSpineGroup(name: "公司出口", type: "select", memberCount: 2)],
        outbounds: broken
            ? (1...9).map { "HK-0\($0)" }
            : ["Office-HK", "Office-SG", "DIRECT", "REJECT"],
        rewriteCount: broken ? 3 : 0,
        scriptNames: broken ? ["mark-sub"] : [],
        adblockEnabled: true,
        adblockListCount: broken ? 2 : 0,
        dnsPort: 5354,
        dnsUpstreamCount: 2,
        danglingPolicies: broken ? ["Streaming"] : [],
        emptyGroups: broken ? ["Fallback"] : []
    )
}
#endif

