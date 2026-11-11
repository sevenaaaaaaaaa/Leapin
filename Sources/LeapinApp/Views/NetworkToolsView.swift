import SwiftUI
import AppKit
import LeapinRuntime
import LeapinIntegrations

@MainActor
struct NetworkToolsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var sharing: ServiceSharing
    @ObservedObject var debug: DebugChannel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("连接与调试工具").font(LPFont.display(23, weight: .semibold))
                Spacer()
                Button("完成") { app.showNetworkTools = false }.buttonStyle(LPGhostButtonStyle())
            }
            Picker("任务", selection: $app.networkToolPage) {
                Text("分享本地服务").tag(0)
                Text("HTTPS 调试").tag(1)
                Text("工具与致谢").tag(2)
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if app.networkToolPage == 0 { ServiceSharingForm(model: sharing, process: sharing.process) }
                    else if app.networkToolPage == 1 { DebugChannelForm(model: debug, process: debug.process) }
                    else { ToolCreditsView() }
                }.padding(.vertical, 4)
            }
        }.padding(26).frame(width: 800, height: 650).foregroundStyle(LP.text).background(LP.bg)
    }
}

@MainActor
private struct ServiceSharingForm: View {
    @ObservedObject var model: ServiceSharing
    @ObservedObject var process: NetworkToolProcess
    @State private var origin = "http://127.0.0.1:3000"
    @State private var minutes = 30
    @State private var email = ""
    @State private var publicAccess = false
    @State private var plan: ServiceSharePlan?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("把正在开发的服务，分享一会儿。").font(.system(size: 18, weight: .semibold))
            Text("先确定谁可以访问，再建立连接。关闭窗口后分享继续；到期、手动停止或退出 Leapin 时断开。")
                .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
            VStack(alignment: .leading, spacing: 12) {
                TextField("本地服务地址", text: $origin).textFieldStyle(.roundedBorder)
                Picker("有效期", selection: $minutes) {
                    Text("15 分钟").tag(15); Text("30 分钟").tag(30); Text("1 小时").tag(60)
                }.frame(maxWidth: 280)
                Toggle("任何持有链接的人均可访问", isOn: $publicAccess)
                if !publicAccess { TextField("允许访问的邮箱", text: $email).textFieldStyle(.roundedBorder) }
                Text(publicAccess ? "公开链接会把选定本地服务提供给外部访问者。请确认服务中没有无认证的管理入口。" : "邮箱验证需要新版 cloudflared 支持；旧版本会停止并提示升级，不会自动改为公开。")
                    .font(.system(size: 12)).foregroundStyle(LP.textSecondary).fixedSize(horizontal: false, vertical: true)
            }.disabled(model.busy || process.running)
            if let plan {
                VStack(alignment: .leading, spacing: 10) {
                    Text("分享预览").font(.system(size: 14, weight: .semibold))
                    Text("\(plan.origin.absoluteString)\n\(plan.publicAccess ? "任何持有链接的人" : plan.email ?? "") · \(plan.minutes) 分钟")
                        .font(LPFont.mono(12)).textSelection(.enabled)
                    Button("开始限时分享") { Task { await model.start(plan); self.plan = nil } }
                        .buttonStyle(LPPrimaryButtonStyle()).disabled(model.busy || process.running)
                }.padding(16).lpPanel(padding: 0)
            } else {
                Button(model.busy ? "正在连接…" : "预览分享范围") {
                    do { plan = try ServiceSharePlan(origin: origin, minutes: minutes, email: email, publicAccess: publicAccess); error = nil }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(LPPrimaryButtonStyle()).disabled(model.busy || process.running)
            }
            if let message = error ?? model.message ?? process.failure {
                Text(message).font(.system(size: 12)).foregroundStyle(LP.textSecondary).textSelection(.enabled)
            }
            if process.running, let url = model.url {
                VStack(alignment: .leading, spacing: 12) {
                    Text(url.absoluteString).font(LPFont.mono(13)).textSelection(.enabled)
                    if let expires = model.expiresAt { Text("预计结束 \(expires.formatted(date: .omitted, time: .standard))").font(.system(size: 12)) }
                    HStack {
                        Button("复制链接") { copy(url.absoluteString) }.buttonStyle(LPGhostButtonStyle())
                        Button("停止分享") { model.stop() }.buttonStyle(LPGhostButtonStyle())
                    }
                }.padding(16).lpPanel(padding: 0)
            } else if model.busy {
                Button("取消连接") { model.stop(); plan = nil }.buttonStyle(LPGhostButtonStyle())
            }
            Text("Quick Tunnel 为临时开发连接，地址会变化且不支持 SSE。MCP / Agent 流式服务应使用合适的命名隧道方案；当前入口不部署命名隧道。")
                .font(.system(size: 12)).foregroundStyle(LP.textTertiary).fixedSize(horizontal: false, vertical: true)
            ToolAttribution(tool: NetworkTool.catalog[2])
        }
        .onChange(of: origin) { _, _ in plan = nil }
        .onChange(of: email) { _, _ in plan = nil }
        .onChange(of: minutes) { _, _ in plan = nil }
        .onChange(of: publicAccess) { _, _ in plan = nil }
        .onChange(of: process.failure) { _, _ in model.reconcile() }
        .onAppear { model.reconcile() }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

@MainActor
private struct DebugChannelForm: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: DebugChannel
    @ObservedObject var process: NetworkToolProcess
    @State private var host = ""
    @State private var message: String?
    @State private var acknowledged = false
    @State private var upstreamCA: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("只调试你指定的网站。").font(.system(size: 18, weight: .semibold))
            Text("目标 App → 独立 mitmproxy 入口 → 当前 Mihomo → 网站。需要目标 App 支持手动 HTTP 代理；当前不提供自动按 App 接管。")
                .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
            TextField("需要解密的网站域名", text: $host).textFieldStyle(.roundedBorder).disabled(model.busy || process.running)
            HStack {
                Button("指定上游 CA（可选）…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK { upstreamCA = panel.url }
                }.buttonStyle(LPGhostButtonStyle()).disabled(model.busy || process.running)
                if let upstreamCA {
                    Text(upstreamCA.lastPathComponent).font(.system(size: 12))
                    Button("清除") { self.upstreamCA = nil }.buttonStyle(LPGhostButtonStyle()).disabled(model.busy || process.running)
                }
            }
            Toggle("我会为目标 App 配置独立代理，并自行处理调试 CA 信任", isOn: $acknowledged).disabled(model.busy || process.running)
            Text("只记录请求方法、主机、状态、协议与失败标记；不记录正文、路径、参数或认证头。其余网站保持隧道。证书固定或不信任 CA 的 App 仍可能拒绝连接。")
                .font(.system(size: 12)).foregroundStyle(LP.textSecondary).fixedSize(horizontal: false, vertical: true)
            if app.engine.executionKernel != .mihomo || !app.engine.managedKernel.running {
                Text("请先启用一个 Mihomo 方案。切换或停止主网络后，此调试通道会停止。")
                    .font(.system(size: 12)).foregroundStyle(LP.danger)
            }
            HStack {
                Button(model.busy ? "正在启动…" : "建立调试通道") {
                    do {
                        let plan = try DebugChannelPlan(host: host, upstreamPort: app.engine.managedKernel.proxyPort ?? 0, upstreamCA: upstreamCA)
                        message = nil; Task { await model.start(plan) }
                    } catch { message = error.localizedDescription }
                }.buttonStyle(LPPrimaryButtonStyle())
                    .disabled(model.busy || process.running || !acknowledged || SiteTarget(host) == nil || !app.engine.managedKernel.running)
                if model.busy || process.running { Button("停止调试") { model.stop() }.buttonStyle(LPGhostButtonStyle()) }
            }
            if let message = message ?? model.message ?? process.failure {
                Text(message).font(.system(size: 12)).foregroundStyle(LP.textSecondary).textSelection(.enabled)
            }
            if process.running, let port = model.port {
                VStack(alignment: .leading, spacing: 12) {
                    Text("HTTP 代理 127.0.0.1:\(String(port)) · 解密 \(model.host ?? host)").font(LPFont.mono(12))
                    HStack {
                        Button("复制终端代理") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("export http_proxy=http://127.0.0.1:\(port) https_proxy=http://127.0.0.1:\(port)", forType: .string)
                        }.buttonStyle(LPGhostButtonStyle())
                        Button("显示调试 CA") { NSWorkspace.shared.activateFileViewerSelecting([model.certificateURL]) }
                            .buttonStyle(LPGhostButtonStyle()).disabled(!FileManager.default.fileExists(atPath: model.certificateURL.path))
                        Button("刷新请求") { model.refresh() }.buttonStyle(LPGhostButtonStyle())
                    }
                }.padding(16).lpPanel(padding: 0)
            }
            if !model.requests.isEmpty {
                Text("最近请求 · 最多 100 条元数据").font(.system(size: 13, weight: .semibold))
                ForEach(model.requests.reversed()) { request in
                    Text("\(request.method) \(request.host):\(request.port) · \(request.failed ? "失败" : "HTTP \(request.status ?? 0)") · \(request.http ?? "未知协议")")
                        .font(LPFont.mono(11)).textSelection(.enabled)
                }
            }
            ToolAttribution(tool: NetworkTool.catalog[1])
        }.onAppear { model.refresh() }
    }
}

@MainActor
private struct ToolCreditsView: View {
    @State private var versions: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("能力来自开源，作者应被看见。").font(.system(size: 18, weight: .semibold))
            Text("Leapin 管理适配与任务执行，内核和工具由原项目提供。当前使用本机可执行文件，不捆绑下载，不自动更新工具。")
                .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
            ForEach(NetworkTool.catalog) { tool in
                VStack(alignment: .leading, spacing: 12) {
                    Text(tool.title).font(.system(size: 15, weight: .semibold))
                    Text(tool.purpose).font(.system(size: 12))
                    Text(versions[tool.id] ?? (NetworkTool.executable(tool.id) == nil ? "未发现可执行文件" : "已发现，待读取版本"))
                        .font(LPFont.mono(11)).foregroundStyle(LP.textSecondary).textSelection(.enabled)
                    Button("选择 \(tool.id) 可执行文件…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = false
                        guard panel.runModal() == .OK, let url = panel.url, FileManager.default.isExecutableFile(atPath: url.path) else { return }
                        UserDefaults.standard.set(url.path, forKey: "leapin.\(tool.id).path")
                        Task { await discover(tool) }
                    }.buttonStyle(LPGhostButtonStyle())
                    Button("重新检测版本") { Task { await discover(tool) } }.buttonStyle(LPGhostButtonStyle())
                    ToolAttribution(tool: tool)
                }.padding(16).lpPanel(padding: 0)
            }
        }.task {
            await withTaskGroup(of: Void.self) { group in
                for tool in NetworkTool.catalog { group.addTask { await discover(tool) } }
            }
        }
    }
    private func discover(_ tool: NetworkTool) async {
        do { versions[tool.id] = try await NetworkTool.version(tool.id) }
        catch { versions[tool.id] = "版本读取未完成，可重试：\(error.localizedDescription)" }
    }
}

private struct ToolAttribution: View {
    let tool: NetworkTool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LPDivider()
            Text("由 \(tool.title) 提供能力 · \(tool.license)").font(.system(size: 11)).foregroundStyle(LP.textSecondary)
            HStack(spacing: 16) {
                Link("原项目与作者", destination: tool.upstream)
                Link("官方文档", destination: tool.documentation)
                Link("许可证", destination: tool.licenseURL)
            }.font(.system(size: 12))
        }
    }
}
