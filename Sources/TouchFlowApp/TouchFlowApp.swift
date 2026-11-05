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
    @StateObject private var app = AppModel()

    var body: some Scene {
        Window("TouchFlow", id: "main") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 1040, minHeight: 700)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("重新载入配置") { Task { await app.engine.reloadProfile() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(app)
        } label: {
            Image(systemName: app.engine.state == .running ? "shield.lefthalf.filled" : "shield.slash")
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
    }

    let engine = TouchFlowEngine.shared
    @Published var section: Section? = .dashboard
    @Published var toast: String?
    @Published var showImporter = false
    @Published var showCAInstaller = false

    init() {
        engine.refreshSystemProxyStatus()
    }

    var isRunning: Bool { engine.state == .running }

    func toggle() {
        Task {
            if engine.state == .running { engine.stop() }
            else { await engine.start() }
        }
    }

    func importProfile(url: URL) {
        Task {
            do {
                let profile = try await engine.importProfile(from: url)
                toast = "已导入 \(profile.name)"
            } catch {
                toast = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    func exportProfile(format: ProfileFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "touchflow-\(format == .clash ? "clash.yaml" : format == .surge ? "surge.conf" : "profile.json")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try engine.exportProfile(format)
            try text.write(to: url, atomically: true, encoding: .utf8)
            toast = "已导出到 \(url.lastPathComponent)"
        } catch {
            toast = "导出失败：\(error.localizedDescription)"
        }
    }

    func installCA() {
        let caURL = engine.store.root.appendingPathComponent("ca/touchflow-ca.pem")
        guard FileManager.default.fileExists(atPath: caURL.path) else {
            toast = "请先在设置中开启 HTTPS 解密并启动一次代理以生成 CA"
            return
        }
        NSWorkspace.shared.open(caURL)
        toast = "已打开 CA 证书，请在“钥匙串访问”中添加到系统并设为始终信任"
    }
}

@MainActor
struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var engine = TouchFlowEngine.shared

    var body: some View {
        NavigationSplitView {
            List(AppModel.Section.allCases, selection: $app.section) { section in
                Label(section.title, systemImage: section.icon).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                StatusPill(state: engine.state)
                    .padding(10)
            }
        } detail: {
            Group {
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
            .environmentObject(app)
        }
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                Text(toast)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 2_600_000_000)
                        withAnimation { app.toast = nil }
                    }
            }
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
}

struct StatusPill: View {
    let state: EngineState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(state.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .help(state.label)
    }

    private var color: Color {
        switch state {
        case .running: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }
}

@MainActor
struct MenuBarPanel: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let engine = app.engine
        Text(engine.state.label)
        Divider()
        Button(engine.state == .running ? "停止代理" : "启动代理") { app.toggle() }
        Button("打开主窗口") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Toggle("系统代理", isOn: Binding(
            get: { engine.systemProxyActive },
            set: { engine.toggleSystemProxy($0) }
        ))
        Divider()
        Button("退出 TouchFlow") { NSApp.terminate(nil) }
    }
}
