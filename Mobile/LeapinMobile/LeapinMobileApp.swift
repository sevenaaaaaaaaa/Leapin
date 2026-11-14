import SwiftUI

@main
struct LeapinMobileApp: App {
    @State private var store = ConsoleStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(LP.accent)
                .preferredColorScheme(nil)
        }
    }
}

struct RootView: View {
    @Environment(ConsoleStore.self) private var store

    var body: some View {
        Group {
            if store.endpoint == nil {
                SetupView()
            } else {
                ConsoleTabs()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.endpoint == nil)
        .onAppear {
            if store.endpoint != nil {
                store.startPolling()
                Task { await store.refresh() }
            }
        }
    }
}

struct ConsoleTabs: View {
    @Environment(ConsoleStore.self) private var store
    @State private var selection = ConsoleTabs.initialTab
    @State private var showSettings = false

    /// DEBUG-only: `LEAPIN_MOBILE_TAB=0…3` opens straight to a tab for screenshots.
    static var initialTab: Int {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["LEAPIN_MOBILE_TAB"],
           let value = Int(raw), (0...3).contains(value) { return value }
        #endif
        return 0
    }

    var body: some View {
        TabView(selection: $selection) {
            DashboardView()
                .tabItem { Label("状态", systemImage: "gauge.with.dots.needle.50percent") }
                .tag(0)

            ConnectionsView()
                .tabItem { Label("连接", systemImage: "arrow.left.arrow.right") }
                .tag(1)

            PoliciesView()
                .tabItem { Label("策略", systemImage: "square.stack.3d.up") }
                .tag(2)

            DiagnosticsView()
                .tabItem { Label("诊断", systemImage: "stethoscope") }
                .tag(3)
        }
        .overlay(alignment: .top) {
            if let error = store.lastError {
                ErrorBanner(message: error) { store.clearError() }
                    .padding(.horizontal, LP.gutter)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: store.lastError)
    }
}

struct ErrorBanner: View {
    var message: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(LP.danger)
            Text(message)
                .font(LPFont.caption)
                .foregroundStyle(LP.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LP.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(LP.panelRaised, in: RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous)
                .strokeBorder(LP.danger.opacity(0.35), lineWidth: 1)
        )
    }
}
