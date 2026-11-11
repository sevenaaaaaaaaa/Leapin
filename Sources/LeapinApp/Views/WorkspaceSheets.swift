import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LeapinRuntime
import LeapinCore
import LeapinIntegrations

@MainActor
struct SceneConfigurationView: View {
    @EnvironmentObject private var app: AppModel
    let scene: NetworkScene
    @State private var selection = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(scene.title, systemImage: scene.icon).font(LPFont.display(23, weight: .semibold))
                Spacer()
                Button("关闭") { app.sceneToConfigure = nil }.buttonStyle(LPGhostButtonStyle()).disabled(app.networkBusy)
            }
            Text(scene.detail).font(.system(size: 14)).foregroundStyle(LP.textSecondary)
            Text("为场景绑定一个网络方案，以后可从总览快速切换。")
                .font(.system(size: 13)).foregroundStyle(LP.textSecondary)
            Picker("使用方案", selection: $selection) {
                Text("请选择配置").tag("")
                ForEach(app.engine.profiles) { meta in Text(meta.name).tag(meta.id.uuidString) }
            }
            Text("场景使用所选方案的分流、节点、DNS 与过滤设置。需要专用规则时，请先导入或编辑相应方案。未运行服务时，切换只选定配置，连接后生效。")
                .font(.system(size: 12)).foregroundStyle(LP.textSecondary).fixedSize(horizontal: false, vertical: true)
            LPDivider()
            HStack {
                Button(app.networkBusy ? "正在切换…" : "保存并切换") {
                    if let id = UUID(uuidString: selection) { app.switchScene(scene, profileID: id) }
                }.buttonStyle(LPPrimaryButtonStyle()).disabled(selection.isEmpty || app.networkBusy)
                Button("先导入一个方案") { app.sceneToConfigure = nil; app.beginImport() }.buttonStyle(LPGhostButtonStyle()).disabled(app.networkBusy)
            }
        }
        .padding(26).frame(width: 560).foregroundStyle(LP.text).background(LP.bg)
        .onAppear { selection = (app.scenes.profileID(for: scene) ?? app.engine.profile.id).uuidString }
    }
}

@MainActor
struct BookmarksView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var store: NetworkBookmarks
    @State private var title = ""
    @State private var address = ""
    @State private var message: String?
    @State private var importing = false
    @State private var preview: BookmarkImportPreview?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("常用网站").font(LPFont.display(23, weight: .semibold))
                Spacer()
                Button("导入书签…") { importing = true }.buttonStyle(LPGhostButtonStyle())
                Button("完成") { app.showBookmarks = false }.buttonStyle(LPGhostButtonStyle())
            }
            Text("固定到总览，直接打开或检查网络。支持浏览器导出的 HTML 和 Chromium 书签 JSON，仅在本机解析。")
                .font(.system(size: 12)).foregroundStyle(LP.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let preview {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(preview.source) · 待导入 \(preview.additions.count) · 重复 \(preview.duplicates) · 跳过 \(preview.skipped)")
                        .font(.system(size: 13, weight: .medium))
                    Text("仅保留 HTTP / HTTPS 网站；不导入脚本、文件链接或含登录凭据的地址。文件夹作为标签保留。")
                        .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(preview.additions.prefix(100))) { item in
                                Text("\(item.folder.map { $0 + " / " } ?? "")\(item.title) · \(item.url.absoluteString)")
                                    .font(.system(size: 12)).lineLimit(2).textSelection(.enabled)
                            }
                            if preview.additions.count > 100 { Text("预览前 100 条，将合并全部 \(preview.additions.count) 条。") }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 180)
                    HStack {
                        Button("合并导入") {
                            do { try store.commitImport(preview); self.preview = nil; message = "已导入 \(preview.additions.count) 个网站。可撤销本次导入。" }
                            catch { message = error.localizedDescription }
                        }.buttonStyle(LPPrimaryButtonStyle()).disabled(preview.additions.isEmpty)
                        Button("取消") { self.preview = nil; message = nil }.buttonStyle(LPGhostButtonStyle())
                    }
                }.padding(16).lpPanel(padding: 0)
            } else {
                HStack {
                    TextField("名称", text: $title).textFieldStyle(.roundedBorder).frame(width: 150)
                    TextField("网站 URL", text: $address).textFieldStyle(.roundedBorder).onSubmit(add)
                    Button("添加", action: add).buttonStyle(LPPrimaryButtonStyle()).disabled(address.isEmpty)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.items) { item in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(item.folder.map { $0 + " · " + (item.url.host ?? "") } ?? item.url.host ?? "网站")
                                        .font(.system(size: 12)).foregroundStyle(LP.textSecondary).lineLimit(1)
                                }
                                Spacer()
                                Button("打开") { NSWorkspace.shared.open(item.url) }.buttonStyle(LPGhostButtonStyle())
                                Button("检查") { app.showBookmarks = false; app.openTask(item.url.absoluteString) }.buttonStyle(LPGhostButtonStyle())
                                Button { do { try store.remove(item.id) } catch { message = error.localizedDescription } } label: {
                                    Image(systemName: "minus.circle").foregroundStyle(LP.textSecondary)
                                }.buttonStyle(.plain).accessibilityLabel("移除书签 \(item.title)")
                            }.padding(.vertical, 12)
                            LPDivider()
                        }
                    }
                }.frame(height: 260)
            }
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(LP.textSecondary).textSelection(.enabled) }
            if store.canUndoImport {
                Button("撤销本次导入") {
                    do { try store.undoImport(); message = "已移除本次导入的网站，保留原有及后来添加的书签。" }
                    catch { message = error.localizedDescription }
                }.buttonStyle(LPGhostButtonStyle())
            }
        }.padding(24).frame(width: 720).foregroundStyle(LP.text).background(LP.bg)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.html, .json, .data], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 8 * 1024 * 1024 else { message = "文件超过 8 MB，请分批导入"; return }
                preview = try store.previewImport(data: Data(contentsOf: url, options: .mappedIfSafe), source: url.lastPathComponent)
                message = nil
            } catch { message = error.localizedDescription }
        }
    }
    private func add() {
        do { try store.add(title: title, address: address); title = ""; address = ""; message = nil }
        catch { message = error.localizedDescription }
    }
}

@MainActor
struct KernelCapabilitiesView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var managed = LeapinEngine.shared.managedKernel
    @State private var message: String?
    private let rows: [(String, String, String)] = [
        ("HTTP(S) / SOCKS5", "TCP", "按内核配置"),
        ("Shadowsocks", "两种 AEAD · TCP", "按版本与加密组合预检"),
        ("Trojan", "TCP / TLS", "按版本与传输组合预检"),
        ("VMess / VLESS / Reality", "不能拨号", "交由 Mihomo 预检与执行"),
        ("Hysteria2 / TUIC / WireGuard", "不能拨号", "交由 Mihomo 预检与执行"),
        ("应用 UDP / TUN 接管", "未实现", "显式 SOCKS5 UDP · TUN 仅终端管理员会话"),
        ("DNS 策略", "DoH / DoT / UDP", "来源策略由内核执行 · 无额外 DNS 监听"),
        ("HTTPS 解密", "HTTP/1.1 · 需信任 CA", "独立 mitmproxy 调试通道 · 需配置 App"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("协议与执行能力").font(LPFont.display(23, weight: .semibold))
                Spacer()
                Button("完成") { app.showCapabilities = false }.buttonStyle(LPGhostButtonStyle())
            }
            Text("可识别配置、内核支持与当前网络可用是三件事。节点需先通过所选内核预检，再验证实际连接。")
                .font(.system(size: 13)).foregroundStyle(LP.textSecondary)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 13) {
                GridRow {
                    Text("能力").fontWeight(.semibold)
                    Text("Leapin 原生").fontWeight(.semibold)
                    Text("Mihomo 适配器").fontWeight(.semibold)
                }
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0).foregroundStyle(LP.text)
                        Text(row.1).foregroundStyle(LP.textSecondary)
                        Text(row.2).foregroundStyle(LP.textSecondary)
                    }
                }
            }.font(.system(size: 12))
            LPDivider()
            Text(managed.version ?? (KernelExecutable.mihomo() == nil ? "本机未发现 Mihomo" : "已发现 Mihomo，正在读取版本…"))
                .font(LPFont.mono(12)).textSelection(.enabled)
            HStack {
                Button("选择 Mihomo 可执行文件…") { chooseExecutable() }.buttonStyle(LPGhostButtonStyle())
                Button("导入并检查配置") { app.showCapabilities = false; app.beginImport() }.buttonStyle(LPPrimaryButtonStyle())
            }
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(LP.danger) }
            Link("查看 Mihomo 官方协议与控制文档", destination: URL(string: "https://wiki.metacubex.one/")!)
                .font(.system(size: 12))
        }
        .padding(26).frame(width: 760).foregroundStyle(LP.text).background(LP.bg)
        .task { await managed.discover() }
    }
    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { message = "请选择可执行的 Mihomo 文件"; return }
        UserDefaults.standard.set(url.path, forKey: "leapin.mihomo.path")
        Task { await managed.discover() }
    }
}
