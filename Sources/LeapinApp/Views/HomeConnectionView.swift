import SwiftUI
import AppKit
import LeapinRuntime
import LeapinIntegrations

@MainActor
struct HomeWidget: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var home: HomeConnections
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("回家与设备", systemImage: "house").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("设置") { app.go(to: .home) }.buttonStyle(.plain).foregroundStyle(LP.accent)
            }
            Text(home.saved.map { "\($0.peerName) · \($0.host)" } ?? "绑定家庭设备，随时打开 NAS 或家庭服务。")
                .font(.system(size: 13)).foregroundStyle(LP.textSecondary).lineLimit(2)
            HStack(spacing: 8) {
                Button(home.busy ? "正在检查…" : home.saved == nil ? "设置回家" : "回家") { app.openHome() }
                    .buttonStyle(LPGhostButtonStyle()).disabled(home.busy || app.engine.configurationBusy)
                Button("局域网共享") { app.go(to: .nas) }.buttonStyle(LPGhostButtonStyle())
            }
            Text(home.failed ? (home.message ?? "检查失败，请打开设置") : home.verifiedAt.map { "上次服务检查 \($0.formatted(date: .omitted, time: .shortened))" } ?? "通过 Tailscale 访问选定设备；使用前检查连通性。")
                .font(.system(size: 13)).foregroundStyle(home.failed ? LP.danger : LP.textTertiary).lineLimit(2)
        }.padding(20).frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading).lpPanel(padding: 0)
    }
}

@MainActor
struct HomeConnectionView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var home: HomeConnections
    @State private var peerID = ""
    @State private var resource = ""
    @State private var localError: String?
    private var unavailable: Bool { home.busy || app.engine.configurationBusy || app.engine.state == .starting || cliMissing }
    private var cliMissing: Bool { !home.busy && home.failed && TailscaleConnector.findExecutable() == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("选一台家庭设备，绑定它的 NAS 或 Web 服务。以后点「回家」，检查通过后直接打开。")
                .font(.system(size: 13)).foregroundStyle(LP.textSecondary).fixedSize(horizontal: false, vertical: true)
            tailscaleRow
            Picker("家庭设备", selection: $peerID) {
                Text("选择设备").tag("")
                ForEach(home.snapshot?.peers ?? []) { peer in
                    Text("\(peer.displayName)\(peer.online ? "" : " · 离线")").tag(peer.id)
                }
            }.disabled(unavailable)
            TextField("资源地址，例如 https://nas.example.ts.net:5001/", text: $resource).textFieldStyle(.roundedBorder).disabled(unavailable)
            Text("支持所选设备的完整 Tailscale DNS 名或 IP，协议为 HTTP、HTTPS、SMB。仅该主机优先直连，其他分流沿用当前方案。此入口不配置子网路由或出口节点。")
                .font(.system(size: 13)).foregroundStyle(LP.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let text = localError ?? (home.failed ? home.message : nil) {
                Text(text).font(.system(size: 13)).foregroundStyle(localError != nil || home.failed ? LP.danger : LP.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack {
                Button(home.busy ? "正在检查…" : "检查并保存") {
                    localError = nil
                    Task { _ = await home.configure(peerID: peerID, resource: resource, applyRouting: { try app.engine.refreshHomeRouting() }) }
                }.buttonStyle(LPPrimaryButtonStyle()).disabled(unavailable || peerID.isEmpty || resource.isEmpty)
                if home.saved != nil {
                    Button("打开家庭资源") { app.openHome() }.buttonStyle(LPGhostButtonStyle()).disabled(unavailable)
                    Button("移除绑定") {
                        do { try home.forget(applyRouting: { try app.engine.refreshHomeRouting() }); peerID = ""; resource = ""; localError = nil }
                        catch { localError = error.localizedDescription }
                    }.buttonStyle(LPGhostButtonStyle()).disabled(unavailable)
                }
            }
            LPDivider()
            Text("首次使用请在 Tailscale 登录并让家庭设备上线。已绑定的连接若暂停，点「回家」会尝试按原设置恢复；不会替你登录、切换账号或设定出口。移除绑定只移除 Leapin 的资源入口。")
                .font(.system(size: 13)).foregroundStyle(LP.textTertiary).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, LPSpace.inset)
        .padding(.vertical, 20)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(LP.text)
        .task {
            peerID = home.saved?.peerID ?? ""; resource = home.saved?.resource.absoluteString ?? ""
            if home.snapshot == nil && !home.failed { await home.refresh() }
        }
        .onChange(of: peerID) { _, value in
            guard let peer = home.snapshot?.peers.first(where: { $0.id == value }), value != home.saved?.peerID else { return }
            let host = peer.normalizedDNSName.isEmpty ? (peer.usableAddresses.first ?? "") : peer.normalizedDNSName
            resource = "https://\(host.contains(":") ? "[\(host)]" : host)/"
        }
    }

    /// Tailscale 的状态收成一行：连接了就安静显示，停了给「重连」，没装才给
    /// 「打开 / 安装」并把手动指定 CLI 收进高级折叠。它是前提条件，不该比任务本身还占地方。
    @ViewBuilder private var tailscaleRow: some View {
        HStack(spacing: 8) {
            StatusDot(color: statusColor)
            Text(statusLine)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(cliMissing || home.failed ? LP.danger : LP.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if home.busy { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            contextActions
        }
        if cliMissing {
            DisclosureGroup("高级：手动指定 Tailscale CLI") {
                Button("选择 Tailscale CLI…") { chooseCLI() }.buttonStyle(LPGhostButtonStyle())
            }.font(.system(size: 13))
        }
    }

    private var statusLine: String {
        if home.busy { return "正在读取 Tailscale 状态…" }
        if cliMissing { return "没找到 Tailscale" }
        if home.failed { return "Tailscale 状态读取失败" }
        if let snapshot = home.snapshot { return snapshot.statusText }
        return "尚未读取 Tailscale 状态"
    }

    private var statusColor: Color {
        if home.busy { return LP.amber }
        if cliMissing || home.failed { return LP.danger }
        if home.snapshot?.state == "Running" { return LP.mint }
        return LP.amber
    }

    @ViewBuilder private var contextActions: some View {
        if cliMissing {
            Button("打开 Tailscale") { openTailscale() }.buttonStyle(LPGhostButtonStyle())
            Link("安装 Tailscale", destination: URL(string: "https://tailscale.com/download/mac")!)
                .font(.system(size: 13))
        } else if home.snapshot?.state == "Stopped" {
            Button("重新连接") { Task { await home.reconnect() } }
                .buttonStyle(LPGhostButtonStyle()).disabled(home.busy)
            Button("刷新") { Task { await home.refresh() } }
                .buttonStyle(LPGhostButtonStyle()).disabled(home.busy)
        } else {
            Button("刷新") { Task { await home.refresh() } }
                .buttonStyle(LPGhostButtonStyle()).disabled(home.busy)
        }
    }
    private func chooseCLI() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { localError = "请选择 Tailscale 的可执行文件"; return }
        UserDefaults.standard.set(url.path, forKey: "leapin.tailscale.path")
        Task { await home.refresh() }
    }
    private func openTailscale() {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos")
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys")
        if let url { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
        else { localError = "未找到 Tailscale 客户端，请先安装，或选择已安装的 CLI。" }
    }
}
