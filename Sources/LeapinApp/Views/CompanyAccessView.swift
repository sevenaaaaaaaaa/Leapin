import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LeapinCore
import LeapinNet
import LeapinRuntime
import LeapinIntegrations

@MainActor
struct CompanyWidget: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: CompanyAccess
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("公司内网", systemImage: "building.2").font(.system(size: 15, weight: .semibold))
                Spacer()
                if !model.configuration.companies.isEmpty {
                    Menu(model.active?.name ?? "选择公司") {
                        ForEach(model.configuration.companies) { company in
                            Button(company.name) {
                                do { try model.activate(company.id, apply: { try app.engine.refreshHomeRouting() }) }
                                catch { model.notice(error.localizedDescription, failed: true); app.showCompany = true }
                            }
                        }
                    }.menuStyle(.borderlessButton).frame(maxWidth: 140)
                }
                Button("管理") { app.showCompany = true }.buttonStyle(.plain).foregroundStyle(LP.accent)
            }
            if let company = model.active {
                Text(company.method.title).font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                ForEach(Array(company.resources.prefix(3))) { resource in
                    HStack {
                        Button { app.openCompanyResource(resource) } label: {
                            Label(resource.title, systemImage: "arrow.up.right.square").lineLimit(1)
                        }.buttonStyle(.plain).font(.system(size: 12))
                        Spacer()
                        Button(model.checking == resource.id ? "检查中…" : "检查") { app.inspectCompanyResource(resource) }.disabled(model.checking != nil).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(LP.accent)
                    }
                }
            } else {
                Text("把内网 Git、文档、开发环境放在一起。兼容已有客户端、VPN、浏览器登录和内网代理。")
                    .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                Button("配置公司访问") { app.showCompany = true }.buttonStyle(LPGhostButtonStyle())
            }
            Text(model.failed ? model.message ?? "请打开公司访问检查" : "保存接入方式不等于已经连接或登录。")
                .font(.system(size: 11)).foregroundStyle(model.failed ? LP.danger : LP.textTertiary).lineLimit(2)
        }.padding(20).frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading).lpPanel(padding: 0)
    }
}

@MainActor
struct CompanyAccessView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: CompanyAccess
    @State private var draft = CompanyConnection(name: "")
    @State private var baseline: CompanyConnection?
    @State private var selection = ""
    @State private var portal = ""
    @State private var proxy = ""
    @State private var vpnID = ""
    @State private var services: [SystemVPNService] = []
    @State private var connectionBusy = false
    @State private var resourceTitle = ""
    @State private var resourceAddress = ""
    @State private var editingResource: UUID?
    @State private var localMessage: String?
    @State private var showImporter = false
    @State private var confirmRemove = false
    @State private var expandedResources: Set<UUID> = []
    private var activeDraft: Bool { model.active?.id == draft.id }
    private var unavailable: Bool { app.engine.configurationBusy || app.engine.state == .starting || connectionBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("公司内网", systemImage: "building.2").font(LPFont.display(23, weight: .semibold))
                Spacer()
                Button("完成") { model.cancelCheck(); app.showCompany = false }.buttonStyle(LPGhostButtonStyle())
            }
            HStack(spacing: 10) {
                Picker("编辑公司", selection: Binding(get: { selection }, set: { choose($0) })) {
                    Text("新配置").tag("")
                    ForEach(model.configuration.companies) { Text($0.name).tag($0.id.uuidString) }
                }
                Button("新增") { load(nil) }.buttonStyle(LPGhostButtonStyle())
                Button("导入模板…") { showImporter = true }.buttonStyle(LPGhostButtonStyle())
                Button("导出模板…") { exportTemplate() }.buttonStyle(LPGhostButtonStyle()).disabled(draft.resources.isEmpty)
            }.disabled(unavailable)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let message = localMessage ?? model.message {
                        Text(message).font(.system(size: 12)).foregroundStyle(model.failed ? LP.danger : LP.textSecondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if baseline == nil { connectionForm }
                    if activeDraft { connectionActions }
                    resourceForm
                    if baseline != nil {
                        DisclosureGroup("编辑接入配置") { connectionForm.padding(.top, 10) }.font(.system(size: 13))
                    }
                    Text("仅对当前公司列出的主机配置 TCP 访问，不添加整段网段规则。其他网站沿用现有方案；切换或暂停只影响新连接。独立终端 TUN 不由此入口配置。")
                        .font(.system(size: 12)).foregroundStyle(LP.textTertiary).fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 4)
            }
            LPDivider()
            HStack {
                Button("保存并使用") { save() }.buttonStyle(LPPrimaryButtonStyle())
                    .disabled(unavailable || draft.resources.isEmpty || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if activeDraft {
                    Button("暂停公司分流") {
                        do { try model.activate(nil, apply: { try app.engine.refreshHomeRouting() }); localMessage = nil }
                        catch { localMessage = error.localizedDescription }
                    }.buttonStyle(LPGhostButtonStyle()).disabled(unavailable)
                }
                if baseline != nil { Button("移除本地入口") { confirmRemove = true }.buttonStyle(LPGhostButtonStyle()).disabled(unavailable) }
                Spacer()
                Text(activeDraft ? "当前公司 · 连接状态需检查" : "保存后生效，尚未连接")
                    .font(.system(size: 11)).foregroundStyle(LP.textSecondary)
            }
        }.padding(24).frame(width: 800, height: 620).foregroundStyle(LP.text).background(LP.bg)
        .onAppear { load(model.active ?? model.configuration.companies.first); if let focus = app.companyResourceFocus { expandedResources.insert(focus) } }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1024 * 1024 else { throw LeapinError.invalidConfiguration("模板不能超过 1 MB") }
                let imported = try CompanyAccessTemplate.decode(Data(contentsOf: url)).draft()
                load(nil); draft = imported; portal = imported.portal?.absoluteString ?? ""; proxy = imported.proxy?.absoluteString ?? ""
                localMessage = "模板已带入表单，尚未保存或启用。请核对资源，并绑定本机客户端 / VPN 后再使用。"
            } catch { localMessage = error.localizedDescription }
        }
        .confirmationDialog("移除此公司的本地入口？不会断开 VPN 或删除客户端。", isPresented: $confirmRemove) {
            Button("移除", role: .destructive) {
                do { try model.remove(draft.id, apply: { try app.engine.refreshHomeRouting() }); load(model.active ?? model.configuration.companies.first) }
                catch { localMessage = error.localizedDescription }
            }
        }
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("接入方式").font(.system(size: 15, weight: .semibold))
            TextField("公司 / 团队名称", text: $draft.name).textFieldStyle(.roundedBorder)
            Picker("使用方式", selection: $draft.method) { ForEach(CompanyAccessMethod.allCases) { Text($0.title).tag($0) } }
            Text(methodHint).font(.system(size: 12)).foregroundStyle(LP.textSecondary).fixedSize(horizontal: false, vertical: true)
            if draft.method == .systemVPN {
                HStack {
                    Picker("本机 VPN", selection: $vpnID) {
                        Text("请选择").tag("")
                        if let old = draft.vpnServiceID, !services.contains(where: { $0.id == old }) { Text("已绑定连接 · 刷新确认").tag(old.uuidString) }
                        ForEach(services) { Text("\($0.name) · \($0.status)").tag($0.id.uuidString) }
                    }
                    Button(connectionBusy ? "读取中…" : "读取系统 VPN") { readVPNs() }.buttonStyle(LPGhostButtonStyle()).disabled(connectionBusy)
                }
            }
            if draft.method.isProxy { TextField("代理地址，例如 https://proxy.corp:8443 或 socks5://proxy.corp:1080", text: $proxy).textFieldStyle(.roundedBorder) }
            HStack {
                Button("选择公司客户端…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowedContentTypes = [.applicationBundle]
                    if panel.runModal() == .OK { draft.application = panel.url }
                }.buttonStyle(LPGhostButtonStyle())
                if let application = draft.application {
                    Text(application.deletingPathExtension().lastPathComponent).font(.system(size: 12)).lineLimit(1)
                    Button("清除") { draft.application = nil }.buttonStyle(LPGhostButtonStyle())
                }
            }
            TextField(draft.method == .browser ? "统一登录入口（必填）" : "登录 / 接入网址（可选）", text: $portal).textFieldStyle(.roundedBorder)
            DisclosureGroup("接入说明（不填写密码或临时令牌）") {
                TextEditor(text: $draft.notes).font(.system(size: 12)).frame(height: 70)
                Text("说明会包含在导出的团队模板中。").font(.system(size: 11)).foregroundStyle(LP.textTertiary)
            }.font(.system(size: 12))
        }.disabled(unavailable).padding(16).lpPanel(padding: 0)
    }

    private var resourceForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("常用资源").font(.system(size: 15, weight: .semibold))
            HStack {
                TextField("名称，例如 内网 Git", text: $resourceTitle).textFieldStyle(.roundedBorder).frame(width: 150)
                TextField("网址 / 内网主机 / SMB / SSH 地址", text: $resourceAddress).textFieldStyle(.roundedBorder)
                Button(editingResource == nil ? "添加" : "更新") { addResource() }.buttonStyle(LPGhostButtonStyle()).disabled(resourceAddress.isEmpty || unavailable)
            }
            if !activeDraft { Text("保存并使用后，可检查和打开这些资源。").font(.system(size: 12)).foregroundStyle(LP.textSecondary) }
            ForEach(draft.resources) { resource in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(resource.title).font(.system(size: 13, weight: .medium))
                            Text(resource.url.absoluteString).font(LPFont.mono(11)).foregroundStyle(LP.textSecondary).lineLimit(2).textSelection(.enabled)
                        }
                        Spacer()
                        Button("编辑") { editingResource = resource.id; resourceTitle = resource.title; resourceAddress = resource.url.absoluteString }.buttonStyle(.plain).font(.system(size: 12))
                        Button { draft.resources.removeAll { $0.id == resource.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).accessibilityLabel("移除草稿资源 \(resource.title)")
                        if activeDraft, model.active?.resources.contains(resource) == true {
                            Button(model.checking == resource.id ? "检查中…" : "检查") { check(resource) }
                                .buttonStyle(LPGhostButtonStyle()).disabled(model.checking != nil || unavailable)
                            Button("打开") { app.openCompanyResource(resource) }.buttonStyle(LPGhostButtonStyle()).disabled(unavailable)
                        }
                    }
                    if let report = model.reports[resource.id], report.companyID == model.active?.id {
                        DisclosureGroup("上次检查 \(report.date.formatted(date: .omitted, time: .standard)) · \(report.hasProblem ? "待处理" : "已取得路径证据")", isExpanded: Binding(get: { expandedResources.contains(resource.id) }, set: { if $0 { expandedResources.insert(resource.id) } else { expandedResources.remove(resource.id) } })) {
                            ForEach(report.steps) { step in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(step.title).fontWeight(.medium).foregroundStyle(step.problem ? LP.danger : LP.text)
                                    Text(step.detail).foregroundStyle(LP.textSecondary).textSelection(.enabled)
                                }.font(.system(size: 12)).padding(.top, 8)
                            }
                        }.font(.system(size: 12))
                    }
                    LPDivider()
                }
            }
            if model.checking != nil { Button("停止检查") { model.cancelCheck() }.buttonStyle(LPGhostButtonStyle()) }
        }.padding(16).lpPanel(padding: 0)
    }

    private var connectionActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接与登录").font(.system(size: 15, weight: .semibold))
            if let active = model.active {
                HStack {
                    if let application = active.application {
                        Button("打开公司客户端") {
                            NSWorkspace.shared.openApplication(at: application, configuration: .init()) { _, error in
                                if let error { Task { @MainActor in model.notice("客户端未打开：\(error.localizedDescription)", failed: true) } }
                            }
                        }.buttonStyle(LPGhostButtonStyle())
                    }
                    if let portal = active.portal { Button("打开登录入口") { NSWorkspace.shared.open(portal) }.buttonStyle(LPGhostButtonStyle()) }
                    if active.method == .systemVPN {
                        Button(connectionBusy ? "请求中…" : "发起已配置 VPN 连接") { startVPN() }.buttonStyle(LPGhostButtonStyle()).disabled(connectionBusy)
                    }
                    if active.method.isProxy {
                        Button("接入 Leapin 系统代理") { app.connectNetwork() }.buttonStyle(LPGhostButtonStyle()).disabled(app.networkBusy)
                    }
                }
            }
            Text("登录、MFA、设备检查和网关权限由公司官方工具完成。此入口不代填公司密码、不关闭证书校验，也不会发布公网链接。")
                .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
        }.padding(16).lpPanel(padding: 0)
    }

    private var methodHint: String {
        switch draft.method {
        case .client: return "选择任意已安装的公司客户端，或使用已经连接的办公网络。所列主机走系统 / VPN 路径与系统 DNS，不向 Leapin 公共 DNS 回退。"
        case .systemVPN: return "只连接 macOS 已配置的 VPN；不创建账号或改变网关参数。未出现在列表里的厂商工具，请选择已有客户端方式。"
        case .browser: return "适合统一登录、反向代理门户和浏览器访问网关。保留原有网络策略，由浏览器处理 SSO。"
        case .httpProxy, .socksProxy: return "仅所列 Web 主机经过此专用代理，目标域名交给代理解析。当前不处理 PAC / NTLM / Kerberos 或代理凭据；这类认证请交由公司客户端。目标 App 仍需经过 Leapin 入口。"
        }
    }
    private func choose(_ value: String) { load(model.configuration.companies.first { $0.id.uuidString == value }) }
    private func load(_ company: CompanyConnection?) {
        baseline = company; draft = company ?? CompanyConnection(name: "")
        selection = company?.id.uuidString ?? ""; portal = company?.portal?.absoluteString ?? ""; proxy = company?.proxy?.absoluteString ?? ""
        vpnID = company?.vpnServiceID?.uuidString ?? ""; resourceTitle = ""; resourceAddress = ""; editingResource = nil; localMessage = nil
    }
    private func candidate() throws -> CompanyConnection {
        var result = draft
        for value in [portal, proxy] where !value.isEmpty {
            guard URL(string: value) != nil else { throw LeapinError.invalidConfiguration("入口地址格式无效") }
        }
        result.portal = portal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : URL(string: portal.trimmingCharacters(in: .whitespacesAndNewlines))
        result.proxy = proxy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : URL(string: proxy.trimmingCharacters(in: .whitespacesAndNewlines))
        result.vpnServiceID = UUID(uuidString: vpnID)
        try result.validate(); return result
    }
    private func save() {
        do { let value = try candidate(); try model.save(value, expected: baseline, apply: { try app.engine.refreshHomeRouting() }); load(value) }
        catch { localMessage = error.localizedDescription }
    }
    private func addResource() {
        do {
            let resource = try CompanyResource(id: editingResource ?? UUID(), title: resourceTitle, address: resourceAddress)
            if let index = draft.resources.firstIndex(where: { $0.id == resource.id }) { draft.resources[index] = resource }
            else { draft.resources.append(resource) }
            resourceTitle = ""; resourceAddress = ""; editingResource = nil; localMessage = nil
        } catch { localMessage = error.localizedDescription }
    }
    private func check(_ resource: CompanyResource) {
        localMessage = nil
        expandedResources.insert(resource.id)
        app.inspectCompanyResource(resource)
    }
    private func readVPNs() {
        connectionBusy = true
        Task {
            defer { connectionBusy = false }
            do { services = try await SystemVPNConnector().services(); localMessage = services.isEmpty ? "系统列表为空；其他公司工具请使用客户端入口。" : nil }
            catch { localMessage = error.localizedDescription }
        }
    }
    private func startVPN() {
        guard let id = model.active?.vpnServiceID else { return }
        model.cancelCheck()
        connectionBusy = true
        Task {
            defer { connectionBusy = false }
            do { let status = try await SystemVPNConnector().start(id); model.notice("连接管理器状态：\(status)。请完成客户端认证，再检查内网资源。") }
            catch { model.notice(error.localizedDescription, failed: true) }
        }
    }
    private func exportTemplate() {
        do {
            let value = try candidate()
            let panel = NSSavePanel(); panel.nameFieldStringValue = "公司资源模板.json"; panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let file = panel.url else { return }
            try CompanyAccessTemplate(value).data().write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            localMessage = "已导出资源和接入说明；不包含本机应用路径、VPN 标识或专用账号字段。网址和说明会原样保留，模板没有被上传。"
        } catch { localMessage = error.localizedDescription }
    }
}
