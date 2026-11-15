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
        // Tools come first and never depend on a Mac: opening the app used to dead-end
        // on a pairing screen, which made it useless until the user walked back to the
        // desktop for a token.
        ConsoleTabs()
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

    /// DEBUG-only: `LEAPIN_MOBILE_TAB=0…4` opens straight to a tab for screenshots.
    static var initialTab: Int {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["LEAPIN_MOBILE_TAB"],
           let value = Int(raw), (0...4).contains(value) { return value }
        #endif
        return 0
    }

    var body: some View {
        TabView(selection: $selection) {
            ToolsView()
                .tabItem { Label("工具", systemImage: "wrench.and.screwdriver") }
                .tag(0)

            paired { DashboardView() }
                .tabItem { Label("状态", systemImage: "gauge.with.dots.needle.50percent") }
                .tag(1)

            paired { ConnectionsView() }
                .tabItem { Label("连接", systemImage: "arrow.left.arrow.right") }
                .tag(2)

            paired { PoliciesView() }
                .tabItem { Label("策略", systemImage: "square.stack.3d.up") }
                .tag(3)

            paired { DiagnosticsView() }
                .tabItem { Label("诊断", systemImage: "stethoscope") }
                .tag(4)
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

    /// Console pages need a paired Mac; until then they explain that instead of
    /// showing an empty screen, and point back at the tools that do work.
    @ViewBuilder
    private func paired<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if store.endpoint == nil {
            UnpairedPage()
        } else {
            content()
        }
    }
}

private struct UnpairedPage: View {
    @Environment(ConsoleStore.self) private var store
    @State private var showSetup = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(LP.textTertiary)
            Text("这个页面需要连接 Mac")
                .font(LPFont.section)
                .foregroundStyle(LP.text)
            Text("「工具」页的 DNS、HTTP 探测和本机网络不需要连接，随时可用。")
                .font(LPFont.caption)
                .foregroundStyle(LP.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("连接 Mac") { showSetup = true }
                .buttonStyle(LPButtonStyle())
                .frame(width: 180)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LP.canvas)
        .sheet(isPresented: $showSetup) {
            NavigationStack {
                SetupView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("关闭") { showSetup = false }
                        }
                    }
            }
            .onChange(of: store.endpoint) { _, value in
                if value != nil { showSetup = false }
            }
        }
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
