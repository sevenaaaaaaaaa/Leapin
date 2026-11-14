import AppKit
import SwiftUI
import LeapinRuntime

/// Owns the always-on-top live panel.
///
/// The main window is usually closed while Leapin just protects traffic in the
/// background, so the floating panel is the one surface that stays in view. It is
/// a non-activating panel: clicking its buttons never steals focus from the app
/// the user is actually working in, and it survives Space switches.
@MainActor
final class FloatingPanelController: ObservableObject {
    static let shared = FloatingPanelController()

    @Published private(set) var isVisible = false

    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?

    private static let enabledKey = "lp.floating.enabled"
    private static let frameKey = "lp.floating.frame"

    private init() {}

    /// Menu bar, menu command and the dashboard all call this.
    func toggle() {
        isVisible ? hide() : show()
    }

    func show(engine: LeapinEngine = .shared) {
        let panel = panel ?? makePanel(engine: engine)
        self.panel = panel
        panel.orderFrontRegardless()
        isVisible = true
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
    }

    /// Brings the panel back on launch when it was left on last time.
    func restoreIfNeeded(engine: LeapinEngine = .shared) {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        show(engine: engine)
    }

    private func makePanel(engine: LeapinEngine) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 272, height: 188),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FloatingStatusView(engine: engine, controller: self))
        panel.setFrameAutosaveName("lp.floating.panel")

        if let saved = UserDefaults.standard.string(forKey: Self.frameKey),
           !saved.isEmpty {
            panel.setFrame(NSRectFromString(saved), display: true)
        } else if let screen = NSScreen.main {
            // Default: top-right corner, just under the menu bar.
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - 292, y: visible.maxY - 12))
        }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak panel] _ in
            guard let panel else { return }
            UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
        }
        return panel
    }
}

#if DEBUG
extension FloatingPanelController {
    /// Renders the panel to a PNG without asking for screen-recording permission.
    /// Used by the UI check (`LEAPIN_SNAPSHOT_PANEL=/tmp/panel.png`), never in release.
    func snapshot(to path: String) {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
#endif

extension Notification.Name {
    /// Posted by the menu command so the panel can be toggled from anywhere.
    static let lpToggleFloatingPanel = Notification.Name("lp.floating.toggle")
}
