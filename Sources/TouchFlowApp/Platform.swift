import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import TouchFlowRuntime

extension Notification.Name {
    static let tfNavigate = Notification.Name("tf.navigate")
    static let tfTogglePalette = Notification.Name("tf.palette.toggle")
    static let tfSearchFocus = Notification.Name("tf.search.focus")
}

/// Keeps window size/position across launches without a storyboard.
struct WindowAutosave: NSViewRepresentable {
    var name: String = "TouchFlowMain"

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setFrameAutosaveName(name)
            window.minSize = NSSize(width: 900, height: 640)
            // 上次的显示器可能已断开：窗口不在任何可见屏幕内时回到主屏中央。
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
                window.center()
                window.saveFrame(usingName: name)
            }
            // 标题栏并入纸面：不显示标题文字，底色跟随内容，而不是系统的灰。
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(TF.bg)
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 让标题栏跟随内容主题，避免深色内容配浅色窗框。
        if ProcessInfo.processInfo.environment["TF_APPEARANCE"] == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if ProcessInfo.processInfo.environment["TF_APPEARANCE"] == "light" {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        GlobalHotKeyCenter.shared.onFire = {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .tfTogglePalette, object: nil)
        }
        GlobalHotKeyCenter.shared.register()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        let engine = TouchFlowEngine.shared
        if engine.systemProxyActive {
            engine.toggleSystemProxy(false)
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let engine = TouchFlowEngine.shared
        let menu = NSMenu()

        let toggleTitle = engine.state == .running ? "停止代理" : "启动代理"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(dockToggleProxy), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let proxyItem = NSMenuItem(title: engine.systemProxyActive ? "关闭系统代理" : "开启系统代理",
                                   action: #selector(dockToggleSystemProxy), keyEquivalent: "")
        proxyItem.target = self
        menu.addItem(proxyItem)
        menu.addItem(.separator())

        for section in [AppModel.Section.dashboard, .rules, .capture, .settings] {
            let item = NSMenuItem(title: section.title, action: #selector(dockOpenSection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = section.rawValue
            menu.addItem(item)
        }
        return menu
    }

    @objc private func dockToggleProxy() {
        let engine = TouchFlowEngine.shared
        if engine.state == .running { engine.stop() }
        else { Task { await engine.start() } }
    }

    @objc private func dockToggleSystemProxy() {
        let engine = TouchFlowEngine.shared
        engine.toggleSystemProxy(!engine.systemProxyActive)
    }

    @objc private func dockOpenSection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .tfNavigate, object: raw)
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
