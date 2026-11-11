import SwiftUI
import AppKit
import LeapinCore
import LeapinRuntime
import LeapinNet
import LeapinIntegrations

@MainActor
struct ManagedKernelPanel: View {
    @ObservedObject private var engine = LeapinEngine.shared
    @ObservedObject private var managed = LeapinEngine.shared.managedKernel
    @State private var policies: [ManagedPolicy] = []
    @State private var message: String?
    @State private var busy = false
    @State private var target = ""
    @State private var logs = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("Mihomo 运行控制", systemImage: "cpu").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(managed.running ? "本地内核就绪" : "未运行").font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                Button("刷新") { Task { await refresh() } }.buttonStyle(LPGhostButtonStyle()).disabled(busy)
            }
            Text(managed.version ?? "Mihomo").font(LPFont.mono(12)).foregroundStyle(LP.textSecondary)
            ForEach(policies) { policy in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(policy.name).font(.system(size: 13, weight: .medium))
                        Text(policy.type).font(LPFont.mono(10)).foregroundStyle(LP.textSecondary)
                    }
                    Spacer()
                    Menu {
                        ForEach(policy.members, id: \.self) { member in
                            Button(member) { select(policy.name, member) }
                        }
                    } label: {
                        HStack {
                            Text(policy.selected).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                        }
                        .font(.system(size: 12)).foregroundStyle(LP.text)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(LP.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(maxWidth: 260).disabled(busy || policy.type == "LoadBalance")
                }
            }
            HStack {
                TextField("输入网站，测试实际代理路径", text: $target).textFieldStyle(.roundedBorder).onSubmit(test)
                Button(busy ? "检查中…" : "测试路径", action: test)
                    .buttonStyle(LPGhostButtonStyle()).disabled(busy || !managed.running || SiteTarget(target) == nil)
            }
            Text("通过 Leapin 的本地代理向网站根路径发送 HEAD 请求。不会携带粘贴链接的路径参数或浏览器登录信息。")
                .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(LP.textSecondary).textSelection(.enabled) }
            Text("来源 DNS 策略由 Mihomo 执行。显式 SOCKS5 UDP 关联可交给内核；它不等于全设备 UDP 接管，且不经过原生过滤与抓包。")
                .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
            DisclosureGroup("TUN 终端接管 · 需要管理员") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("当前图形包没有特权服务。可预检并导出启动包，在终端审阅后授权运行；不会以 root 启动图形 App。运行前先停止系统代理并退出其他全局接管模式。")
                        .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                    Text("终端会话创建网卡和路由，Ctrl-C 停止自有内核；不写系统 DNS。Tailscale 地址段予以排除，共存及真实 UDP 出口仍需验证。")
                        .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                    Button("预检并导出 TUN 启动包…") { exportTUN() }.buttonStyle(LPGhostButtonStyle()).disabled(busy)
                }.padding(.top, 10)
            }.font(.system(size: 12))
            DisclosureGroup("内核运行日志") {
                Text(logs.isEmpty ? "当前没有内核输出。" : logs)
                    .font(LPFont.mono(12)).foregroundStyle(LP.textSecondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.font(.system(size: 12))
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).lpPanel(padding: 0)
        .task(id: engine.state) { await refresh() }
    }
    private func exportTUN() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                guard let source = try engine.store.kernelSource(for: engine.profile.id) else { return }
                let session = ManagedTUNSession()
                try await session.check(source: source.clash)
                let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/leapin")
                guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw CocoaError(.fileNoSuchFile) }
                let folder = parent.appendingPathComponent("Leapin-TUN-\(UUID().uuidString.prefix(8))")
                let file = try TUNLaunchPlan(source: source.clash).export(to: folder, cli: cli)
                NSWorkspace.shared.activateFileViewerSelecting([file])
                message = "已预检并导出。尚未启动 TUN；先审阅 source.yaml 和 start.command，再在终端授权运行。"
            } catch { message = error.localizedDescription }
        }
    }
    private func refresh() async {
        logs = managed.logs
        guard managed.running else { policies = []; return }
        do { policies = try await engine.managedPolicies() }
        catch { message = Redactor.redact(error.localizedDescription) }
    }
    private func select(_ group: String, _ member: String) {
        busy = true
        Task {
            do { try await engine.selectManagedPolicy(group: group, member: member); message = "已选择 \(member)，仅新连接使用新选择。" }
            catch { message = Redactor.redact(error.localizedDescription) }
            await refresh(); busy = false
        }
    }
    private func test() {
        guard let site = SiteTarget(target), !busy, managed.running else { return }
        busy = true
        Task {
            let result = await ProxyPathProbe.probe(site.origin, port: engine.profile.general.mixedPort)
            message = result.error ?? "代理路径 HEAD 返回 HTTP \(result.statusCode ?? 0) · \(Int(result.elapsedMs)) ms。此结果不代表登录或完整页面功能已验证。"
            logs = managed.logs; busy = false
        }
    }
}
