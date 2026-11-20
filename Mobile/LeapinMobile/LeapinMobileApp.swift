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

            DashboardView()
                .tabItem { Label("状态", systemImage: "gauge.with.dots.needle.50percent") }
                .tag(1)

            ConnectionsView()
                .tabItem { Label("连接", systemImage: "arrow.left.arrow.right") }
                .tag(2)

            PoliciesView()
                .tabItem { Label("策略", systemImage: "square.stack.3d.up") }
                .tag(3)

            DiagnosticsView()
                .tabItem { Label("诊断", systemImage: "stethoscope") }
                .tag(4)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                if let error = store.lastError {
                    ErrorBanner(message: error) { store.clearError() }
                }
                if store.endpoint == nil, selection != 0 {
                    UnpairedBanner()
                }
            }
            .padding(.horizontal, LP.gutter)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
        .animation(.easeInOut(duration: 0.18), value: store.lastError)
        // One sheet for the whole app: any page can ask to pair without owning a
        // presentation of its own.
        .sheet(isPresented: Binding(get: { store.pairingSheetShown },
                                    set: { store.pairingSheetShown = $0 })) {
            PairingScannerView()
        }
    }

}

/// Thin strip above a console page while no Mac is paired: the page still shows
/// its real structure, this only explains why the numbers are empty.
private struct UnpairedBanner: View {
    @Environment(ConsoleStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 11))
                .foregroundStyle(LP.textTertiary)
            Text("未连接 Mac，下面是本机与空数据")
                .font(LPFont.micro)
                .foregroundStyle(LP.textSecondary)
            Spacer(minLength: 4)
            Button("扫码配对") { store.pairingSheetShown = true }
                .font(LPFont.micro.weight(.semibold))
                .foregroundStyle(LP.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(LP.panelRaised, in: RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous)
                .strokeBorder(LP.stroke, lineWidth: 1)
        )
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