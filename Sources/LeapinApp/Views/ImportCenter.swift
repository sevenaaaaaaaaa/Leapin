import SwiftUI
import AppKit
import LeapinCore
import LeapinRuntime
import LeapinPolicy
import LeapinIntegrations

@MainActor
struct ImportCenter: View {
    @EnvironmentObject private var app: AppModel
    @State private var input = ""
    @State private var name = ""
    @State private var inputKind = 0
    @State private var kernel: ExecutionKernel = .native
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false
    @State private var validated: ExecutionKernel?
    @State private var connectSystem = false
    @State private var fileDialog = false
    @State private var exportFormat: ProfileFormat = .clash
    @State private var completed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("带入你的网络方案").font(LPFont.display(23, weight: .semibold))
                    Text("先检查，再决定。当前配置会保留到新方案就绪。")
                        .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                }
                Spacer()
                Button("完成") { app.showImportCenter = false }.buttonStyle(LPGhostButtonStyle()).disabled(busy)
            }.padding(24)
            LPDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let candidate = app.pendingImport { preview(candidate) }
                    else { inputForm }
                }.padding(24)
            }
            .frame(minHeight: 220, maxHeight: .infinity)
            if app.pendingImport != nil || message != nil {
                LPDivider()
                VStack(alignment: .leading, spacing: 12) {
                    if let message {
                        Text(message).font(.system(size: 12)).foregroundStyle(failed ? LP.danger : LP.textSecondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if let candidate = app.pendingImport { primaryAction(candidate) }
                }.padding(.horizontal, 24).padding(.vertical, 16)
            }
        }
        .frame(width: 720, height: 640)
        .foregroundStyle(LP.text)
        .background(LP.bg)
        .onAppear { chooseKernel() }
        .onChange(of: kernel) { _, _ in validated = nil; completed = false; message = nil }
        .fileImporter(isPresented: $fileDialog, allowedContentTypes: [.yaml, .json, .plainText, .data]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
                    throw LeapinError.invalidConfiguration("请选择 8 MB 内的 UTF-8 配置文件")
                }
                app.pendingImport = try ImportPreparation(text: text, name: url.deletingPathExtension().lastPathComponent,
                    origin: url.lastPathComponent, pathExtension: url.pathExtension)
                chooseKernel()
            } catch { fail(error) }
        }
    }

    private var inputForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("来源", selection: $inputKind) {
                Text("订阅链接").tag(0)
                Text("配置文本 / 节点列表").tag(1)
            }.pickerStyle(.segmented)
            TextField("方案名称（可选）", text: $name).textFieldStyle(.roundedBorder)
            if inputKind == 0 {
                TextField("粘贴 http(s) 订阅地址", text: $input).textFieldStyle(.roundedBorder)
                    .onSubmit { prepare() }.accessibilityLabel("订阅链接")
            } else {
                TextEditor(text: $input).font(LPFont.mono(12)).frame(height: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LP.stroke))
                    .accessibilityLabel("配置或节点文本")
            }
            HStack {
                Button(busy ? "正在检查…" : "检查兼容性") { prepare() }
                    .buttonStyle(LPPrimaryButtonStyle()).disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("选择文件…") { fileDialog = true }.buttonStyle(LPGhostButtonStyle()).disabled(busy)
                Spacer()
            }
            Text("支持 Clash / Mihomo YAML、Surge conf、Leapin JSON 与节点订阅。订阅直接下载到本机，不发送给公共转换服务。")
                .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
        }.disabled(busy)
    }

    private func preview(_ candidate: ImportPreparation) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(candidate.outcome.profile.name).font(.system(size: 18, weight: .semibold))
                    Text("\(candidate.origin) · \(candidate.outcome.report.format)")
                        .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                }
                Spacer()
                Button("更换来源") {
                    app.pendingImport = nil; validated = nil; message = nil; completed = false
                }.buttonStyle(LPGhostButtonStyle()).disabled(busy)
            }
            HStack(spacing: 24) {
                count("节点", candidate.outcome.profile.outbounds.filter { $0.type != .direct && $0.type != .reject }.count)
                count("策略组", candidate.outcome.profile.groups.count)
                count("规则", candidate.outcome.profile.rules.count)
                count("原生不兼容项", candidate.nativeBlockers.count)
            }
            LPDivider()
            VStack(alignment: .leading, spacing: 10) {
                Text("用什么运行").font(.system(size: 13, weight: .semibold))
                Picker("执行内核", selection: $kernel) {
                    Text("Leapin 原生").tag(ExecutionKernel.native)
                    Text(KernelExecutable.mihomo() == nil ? "Mihomo · 未找到" : "Mihomo · 已检测到").tag(ExecutionKernel.mihomo)
                }.pickerStyle(.segmented)
                Text(kernel == .native ? "使用原生 TCP 代理、DNS 与过滤能力。协议和传输必须在原生支持范围内。"
                     : "由 Mihomo 执行分流与协议；Leapin 提供本地入口。TUN、额外监听与内核 DNS 接管关闭，来源专属 DNS 策略暂未完整透传；分流修改需重新导入。")
                    .font(.system(size: 12)).foregroundStyle(LP.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if !candidate.nativeBlockers.isEmpty {
                DisclosureGroup("原生不兼容的 \(candidate.nativeBlockers.count) 项") {
                    ForEach(candidate.nativeBlockers, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(LP.amber) }
                }.font(.system(size: 12))
            }
            if kernel == .mihomo && !candidate.externalConversionBlockers.isEmpty {
                Text("此来源转换存在信息损失，暂不能启用。请提供原始 Clash / Mihomo 配置，或先处理解析报告。")
                    .font(.system(size: 12)).foregroundStyle(LP.danger)
            }
            if !candidate.outcome.report.issues.isEmpty {
                DisclosureGroup("解析报告 · \(candidate.outcome.report.issues.count) 项") {
                    ForEach(candidate.outcome.report.issues) { issue in
                        Text(Redactor.redact(issue.display)).font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                    }
                    if kernel == .mihomo && candidate.preservesClashSource {
                        Text("Mihomo 使用原始 Clash 文本；原生解析器的协议警告不代表 Mihomo 不支持。以内核预检为准。")
                            .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                    }
                }.font(.system(size: 12))
            }
            Toggle("同时接入系统代理", isOn: $connectSystem).toggleStyle(.checkbox).font(.system(size: 12))
                .disabled(busy || completed)
            Text("启用会启动本地服务。若原配置已接管系统，会保持接管；失败自动恢复。仅配置预检不代表远端节点或目标网站已经可达。")
                .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
            LPDivider()
            HStack {
                Picker("转换导出", selection: $exportFormat) {
                    Text("Clash / Mihomo YAML").tag(ProfileFormat.clash)
                    Text("Surge conf").tag(ProfileFormat.surge)
                    Text("Leapin JSON").tag(ProfileFormat.json)
                }.frame(maxWidth: 330)
                Button("导出文件…") { export(candidate) }.buttonStyle(LPGhostButtonStyle()).disabled(busy)
            }
            Text(exportFormat == .clash && candidate.preservesClashSource
                 ? "导出保留原始 Clash 文本。受管运行时的本地端口覆盖不会写回来源。"
                 : "转换只导出内部模型可表达的字段。存在解析损失或目标不兼容项时会阻止转换；不会把缺失节点静默删除。")
                .font(.system(size: 12)).foregroundStyle(LP.textSecondary)
        }
    }

    private func primaryAction(_ candidate: ImportPreparation) -> some View {
            HStack(spacing: 10) {
                if completed {
                    Button("查看线路与内核") { app.showImportCenter = false; app.go(to: .profiles) }.buttonStyle(LPPrimaryButtonStyle())
                } else if validated == kernel {
                    Button(busy ? "正在启用…" : "启用这个方案") { activate(candidate) }
                        .buttonStyle(LPPrimaryButtonStyle()).disabled(busy)
                } else {
                    Button(busy ? "正在预检…" : "预检所选内核") { validate(candidate) }
                        .buttonStyle(LPPrimaryButtonStyle()).disabled(busy || (kernel == .native && !candidate.nativeBlockers.isEmpty)
                            || (kernel == .mihomo && (KernelExecutable.mihomo() == nil || !candidate.externalConversionBlockers.isEmpty)))
                }
                Spacer()
            }
    }

    private func count(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(value)").font(LPFont.num(22)).foregroundStyle(LP.text)
            Text(title).font(.system(size: 12)).foregroundStyle(LP.textSecondary)
        }
    }
    private func chooseKernel() {
        if let preparation = app.pendingImport { kernel = preparation.nativeBlockers.isEmpty ? .native : .mihomo }
    }
    private func fail(_ error: Error) { failed = true; message = Redactor.redact(error.localizedDescription); busy = false }
    private func prepare() {
        busy = true; failed = false; message = nil
        Task {
            do {
                if inputKind == 0 { app.pendingImport = try await ImportPreparation.download(input, name: name) }
                else { app.pendingImport = try ImportPreparation(text: input, name: name.isEmpty ? "导入方案" : name) }
                chooseKernel(); busy = false
            } catch { fail(error) }
        }
    }
    private func validate(_ candidate: ImportPreparation) {
        busy = true; failed = false; message = "正在检查配置，不改变当前网络…"
        Task {
            do {
                if kernel == .mihomo {
                    guard candidate.externalConversionBlockers.isEmpty else {
                        throw LeapinError.unsupported("来源转换存在信息损失，不能启用")
                    }
                    let directory = app.engine.store.root.appendingPathComponent("import-check/\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: directory) }
                    try await app.engine.managedKernel.validate(source: candidate.clashSource, directory: directory)
                } else if !candidate.nativeBlockers.isEmpty { throw LeapinError.unsupported("原生内核存在不兼容项") }
                validated = kernel; busy = false; message = "配置预检通过。下一步会启动所选内核并检查本地服务是否就绪。"
            } catch { fail(error) }
        }
    }
    private func activate(_ candidate: ImportPreparation) {
        busy = true; failed = false; message = "正在启用并检查本地服务；失败时恢复原配置…"
        Task {
            do {
                try await app.engine.commitImport(candidate, kernel: kernel, connectSystem: connectSystem)
                completed = true; busy = false
                message = "已启用 \(kernel.title)，本地入口已就绪。远端节点可达性请在线路页选择目标测试。"
            } catch { fail(error); validated = nil }
        }
    }
    private func export(_ candidate: ImportPreparation) {
        do {
            let issues = candidate.outcome.report.issues.filter { $0.kind != .unknownProtocol }
            if exportFormat != .clash || !candidate.preservesClashSource {
                guard issues.isEmpty else { throw LeapinError.unsupported("存在解析差异，无法保证无损转换。请保留原格式或先处理报告中的问题") }
            }
            if exportFormat == .surge {
                guard candidate.nativeBlockers.isEmpty, candidate.outcome.profile.ruleProviders.isEmpty else {
                    throw LeapinError.unsupported("目标 Surge 导出器不能完整表达这些节点或规则集，请导出 Clash / Mihomo 格式")
                }
            }
            let text: String
            switch exportFormat {
            case .clash: text = candidate.clashSource
            case .surge: text = ProfileExporter.surge(candidate.outcome.profile)
            default: text = String(decoding: try JSONEncoder().encode(candidate.outcome.profile), as: UTF8.self)
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "leapin-converted.\(exportFormat.fileExtension)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try Data(text.utf8).write(to: url, options: .atomic)
            failed = false; message = "已导出 \(exportFormat.rawValue)。未改变当前方案。"
        } catch { fail(error) }
    }
}
