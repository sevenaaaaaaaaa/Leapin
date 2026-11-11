import SwiftUI
import Combine
import AppKit
import LeapinCore
import LeapinRuntime

/// A deliberately low-frequency snapshot of the engine: state, active profile and
/// configuration flags only. It never subscribes to flows or stats, so the
/// overview does not re-render on every connection.
@MainActor
final class OverviewModel: ObservableObject {
    @Published var state: EngineState
    @Published var profile: Profile
    @Published var kernel: ExecutionKernel
    @Published var systemProxyActive: Bool

    private var cancellables = Set<AnyCancellable>()

    init() {
        let engine = LeapinEngine.shared
        kernel = engine.executionKernel
        state = engine.state
        profile = engine.profile
        systemProxyActive = engine.systemProxyActive

        engine.$executionKernel.receive(on: RunLoop.main).sink { [weak self] in self?.kernel = $0 }.store(in: &cancellables)
        engine.$state.receive(on: RunLoop.main).sink { [weak self] value in
            Task { @MainActor in self?.state = value }
        }.store(in: &cancellables)
        engine.$profile.receive(on: RunLoop.main).sink { [weak self] value in
            Task { @MainActor in self?.profile = value }
        }.store(in: &cancellables)
        engine.$systemProxyActive.receive(on: RunLoop.main).sink { [weak self] value in
            Task { @MainActor in self?.systemProxyActive = value }
        }.store(in: &cancellables)
    }
}

@MainActor
struct DashboardView: View {
    @EnvironmentObject private var app: AppModel
    var body: some View { DashboardContent(scenes: app.scenes, bookmarks: app.bookmarks) }
}

@MainActor
private struct DashboardContent: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.lpWindowWidth) private var windowWidth
    @StateObject private var model = OverviewModel()
    @ObservedObject var scenes: NetworkScenes
    @ObservedObject var bookmarks: NetworkBookmarks

    private var activeScene: NetworkScene? {
        guard let active = scenes.active, scenes.profileID(for: active) == model.profile.id else { return nil }
        return active
    }
    private var connected: Bool { model.state == .running && model.systemProxyActive }
    private var columns: [GridItem] { [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                statusBar
                HStack(spacing: 10) {
                    Button { app.networkToolPage = 0; app.showNetworkTools = true } label: { Label("分享本地服务", systemImage: "link") }.buttonStyle(LPGhostButtonStyle())
                    Button { app.networkToolPage = 2; app.showNetworkTools = true } label: { Label("工具与致谢", systemImage: "heart") }.buttonStyle(LPGhostButtonStyle())
                    Button { app.showCompany = true } label: { Label("公司内网", systemImage: "building.2") }.buttonStyle(LPGhostButtonStyle())
                    Spacer(minLength: 0)
                }
                sceneRail
                if windowWidth >= 900 {
                    HStack(alignment: .top, spacing: 18) {
                        subscriptionWidget.frame(maxWidth: .infinity)
                        bookmarksWidget.frame(maxWidth: .infinity)
                    }
                } else {
                    subscriptionWidget
                    bookmarksWidget
                }
                HStack {
                    Text("随手可用").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("⌘K 查找更多工具").font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    CompanyWidget(model: app.company)
                    widget("开发与 Agent", icon: "curlybraces", note: "终端、App 分流与服务器") {
                        HStack(spacing: 8) {
                            Button("复制终端代理") { copyTerminal() }.buttonStyle(LPGhostButtonStyle())
                            Button("App 分流") { app.go(to: .learn) }.buttonStyle(LPGhostButtonStyle())
                        }
                        textAction("连接服务器", icon: "terminal") { app.go(to: .ssh) }
                    }
                    HomeWidget(home: app.home)
                    widget("HTTPS 调试通道", icon: "curlybraces.square", note: "mitmproxy 解密 · Mihomo 出站") {
                        Button("调试一个网站") { app.networkToolPage = 1; app.showNetworkTools = true }.buttonStyle(LPGhostButtonStyle())
                        Text("独立入口，限定网站，保留证书校验。").font(.system(size: 12)).foregroundStyle(LP.textTertiary)
                    }
                    widget("网站与网络体检", icon: "stethoscope", note: "检查目标、解释分流与连接异常") {
                        HStack(spacing: 8) {
                            Button("粘贴 URL 检查") { inspectClipboard() }.buttonStyle(LPGhostButtonStyle())
                            Button("打开排障") { app.go(to: .diagnostics) }.buttonStyle(LPGhostButtonStyle())
                        }
                        textAction("连接明细与流量", icon: "waveform.path") { app.go(to: .activity) }
                    }
                    widget("保护与调试", icon: "lock.shield", note: "广告过滤、抓包与隐私检查") {
                        HStack(spacing: 8) {
                            Button("过滤与例外") { app.go(to: .adblock) }.buttonStyle(LPGhostButtonStyle())
                            Button("抓包") { app.go(to: .capture) }.buttonStyle(LPGhostButtonStyle())
                        }
                        textAction("隐私审计", icon: "checkmark.shield") { app.go(to: .privacy) }
                    }
                }
                HStack(spacing: 12) {
                    Image(systemName: "cpu").foregroundStyle(LP.textSecondary)
                    Text("\(model.kernel.title) · \(model.profile.name)")
                        .font(.system(size: 12)).foregroundStyle(LP.textSecondary).lineLimit(1)
                    Spacer()
                    Button("支持哪些协议？") { app.showCapabilities = true }.buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(LP.accent)
                    Button("设置") { app.go(to: .settings) }.buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                }.padding(.top, 4)
            }.pagePadding()
        }
        .foregroundStyle(LP.text)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("你的网络，随需而行。")
                        .font(LPFont.display(26, weight: .semibold)).tracking(-0.5)
                    HStack(spacing: 7) {
                        Circle().fill(connected ? LP.mint : LP.textTertiary).frame(width: 6, height: 6)
                        Text(connected ? "系统代理已接入" : model.state == .running ? "本地服务就绪 · 系统代理未接入" : model.state.label)
                        Text("·")
                        Text(activeScene?.title ?? "尚未选择场景")
                    }.font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                }
                Spacer(minLength: 8)
                Button(connected ? "暂停接管" : app.networkBusy ? "准备中…" : "连接网络") {
                    if connected { app.pauseNetwork() } else { app.connectNetwork() }
                }.buttonStyle(LPGhostButtonStyle()).disabled(app.networkBusy || app.engine.configurationBusy || model.state == .starting)
            }
            if let message = app.networkMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(app.networkFailed ? LP.danger : LP.textSecondary)
            }
        }
    }

    private var sceneRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                LPEyebrow("场景 / SCENES")
                Spacer()
                if let activeScene {
                    Button("调整当前场景") { app.sceneToConfigure = activeScene }.buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(NetworkScene.allCases) { scene in
                    Button { app.switchScene(scene) } label: {
                        VStack(spacing: 8) {
                            Image(systemName: scene.icon).font(.system(size: 18))
                            Text(scene.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(scenes.profileID(for: scene) == nil ? "设置方案" : activeScene == scene ? (model.state == .running ? "使用中" : "已选择") : "可切换")
                                .font(.system(size: 10)).foregroundStyle(activeScene == scene ? LP.accent : LP.textTertiary)
                        }
                        .foregroundStyle(activeScene == scene ? LP.accent : LP.text)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(activeScene == scene ? LP.accent.opacity(0.09) : LP.text.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(activeScene == scene ? LP.accent.opacity(0.3) : LP.stroke))
                        .contentShape(Rectangle())
                    }.buttonStyle(LPCardButtonStyle(radius: 12)).disabled(app.networkBusy)
                        .help(scene.detail).accessibilityLabel("\(scene.title)，\(scenes.profileID(for: scene) == nil ? "未绑定方案" : "切换场景")")
                }
            }
        }
    }

    private var subscriptionWidget: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("线路与订阅", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(model.kernel.title).font(LPFont.mono(10)).foregroundStyle(LP.textSecondary)
            }
            Text(model.profile.name).font(LPFont.display(22, weight: .semibold)).lineLimit(1)
            Text("\(model.profile.outbounds.filter { $0.type != .direct && $0.type != .reject }.count) 个节点 · \(model.profile.groups.count) 个策略组 · \(model.profile.rules.count) 条来源规则")
                .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
            HStack(spacing: 8) {
                Button("导入 / 转换订阅") { app.beginImport() }.buttonStyle(LPPrimaryButtonStyle())
                Button("管理线路") { app.go(to: .profiles) }.buttonStyle(LPGhostButtonStyle())
            }
        }
        .padding(20).frame(maxWidth: .infinity, minHeight: 197, alignment: .topLeading).lpPanel(padding: 0)
    }

    private var bookmarksWidget: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("常用书签", systemImage: "bookmark").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("管理") { app.showBookmarks = true }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(LP.accent)
            }
            if bookmarks.items.isEmpty {
                Text("把常用网站放在这里，打开、检查，一步可达。")
                    .font(.system(size: 13)).foregroundStyle(LP.textSecondary)
                Spacer(minLength: 0)
                Button("添加网站") { app.showBookmarks = true }.buttonStyle(LPGhostButtonStyle())
            } else {
                ForEach(Array(bookmarks.items.prefix(3))) { bookmark in
                    HStack {
                        Button(bookmark.title) { NSWorkspace.shared.open(bookmark.url) }.buttonStyle(.plain)
                            .font(.system(size: 13)).foregroundStyle(LP.text).lineLimit(1)
                        Spacer()
                        Button("检查") { app.openTask(bookmark.url.absoluteString) }.buttonStyle(.plain)
                            .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                    }
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, minHeight: 197, alignment: .topLeading).lpPanel(padding: 0)
    }

    private func widget<Content: View>(_ title: String, icon: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 17)).foregroundStyle(LP.textSecondary).accessibilityHidden(true)
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            Text(note).font(.system(size: 12)).foregroundStyle(LP.textSecondary)
            content()
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        .background(LP.text.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LP.stroke))
    }
    private func textAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 12)).foregroundStyle(LP.textSecondary)
        }.buttonStyle(.plain)
    }
    private func copyTerminal() {
        let port = model.profile.general.mixedPort
        LPClipboard.copy("export http_proxy=http://127.0.0.1:\(port) https_proxy=http://127.0.0.1:\(port) all_proxy=socks5h://127.0.0.1:\(port) no_proxy=localhost,127.0.0.1,::1")
        app.showToast(model.state == .running ? "已复制终端代理环境命令" : "已复制；使用前请先启动网络服务", kind: .info)
    }
    private func inspectClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        if SiteTarget(text) != nil { app.openTask(text) }
        else { app.go(to: .diagnostics); app.requestSearchFocus(); app.showToast("请输入要检查的网站地址", kind: .info) }
    }
}
