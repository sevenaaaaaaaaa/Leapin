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
        if let raw = UserDefaults.standard.string(forKey: "startSection"),
           let s = Section(rawValue: raw) {
            section = s
        }
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
        .overlay(alignment: .bottom) { toast }
        .preferredColorScheme(ProcessInfo.processInfo.environment["TF_APPEARANCE"] == "dark" ? .dark : nil)
        .task {
            if ProcessInfo.processInfo.environment["TF_AUTOSTART"] == "1" {
                await engine.start()
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

    @ViewBuilder private var toast: some View {
        if let message = app.toast {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(TF.mint)
                Text(message).font(.system(size: 11.5, weight: .medium)).foregroundStyle(TF.text)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(TF.panelSolid, in: Capsule())
            .overlay(Capsule().strokeBorder(TF.stroke))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: message) {
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                withAnimation(.easeOut(duration: 0.2)) { app.toast = nil }
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
            brand.padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 18)

            Text("工作区")
                .font(TFFont.overline)
                .tracking(1.1)
                .foregroundStyle(TF.textTertiary)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)

            VStack(spacing: 2) {
                ForEach(AppModel.Section.allCases) { section in
                    SidebarRow(section: section, selected: app.section == section) {
                        withAnimation(.easeOut(duration: 0.12)) { app.section = section }
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
                if selected {
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
        PageHeader(title: section.title, subtitle: subtitle, icon: section.icon) {
            HStack(spacing: 14) {
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

    private var subtitle: String {
        switch section {
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

            Toggle(isOn: Binding(
                get: { engine.systemProxyActive },
                set: { engine.toggleSystemProxy($0) }
            )) {
                Text("系统代理").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            TFDivider()

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
        .frame(width: 220)
    }
}
