import SwiftUI
import LeapinCore
import LeapinPolicy
import LeapinNet
import LeapinRuntime

struct TaskEvidence: Identifiable {
    let id = UUID()
    let title: String
    let value: String
}

@MainActor
final class NetworkAssistantModel: ObservableObject {
    @Published var input = ""
    @Published var directMode = false
    @Published private(set) var task: NetworkTask?
    @Published private(set) var busy = false
    @Published private(set) var evidence: [TaskEvidence] = []
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    @Published private(set) var applied = false
    @Published private(set) var receipt: NetworkRuleChange?
    @Published private(set) var report: NetworkDiagnosticReport?
    /// 原地重测的那个主机：报告卡上的「重新检查」不必再问用户一次（T-12）。
    @Published private(set) var lastTarget: SiteTarget?
    private var preview: Profile?
    private let engine = LeapinEngine.shared

    func submit() {
        let original = input
        let mode = directMode
        prepare(mode ? "让 \(input) 直连" : nil)
        input = original
        directMode = mode
    }

    func prepare(_ text: String? = nil) {
        guard !busy else { return }
        if let text { input = text; directMode = false }
        report = nil
        task = NetworkTask.parse(input)
        preview = engine.profile
        evidence = []
        message = nil
        failed = false
        applied = false
        // Keep the last receipt available even when starting a different task.
    }

    func inspectLocal(capture: Bool = false) {
        guard !busy else { return }
        // 本地检查不是针对某个 host 的：留着上一个 target 会让报告卡上的「重新检查」
        // 偷偷去重测旧主机（T-14 评审 O3）。
        lastTarget = nil
        task = nil; evidence = []; message = nil
        report = NetworkDiagnosticAnalyzer.analyze(diagnosticInput(capture: capture))
    }

    private func diagnosticInput(capture: Bool = false) -> NetworkDiagnosticInput {
        NetworkDiagnosticInput(profileID: engine.profile.id, state: engine.state,
            systemProxyActive: engine.systemProxyActive, kernel: engine.executionKernel,
            managedRunning: engine.managedKernel.running, captureEnabled: engine.profile.general.captureEnabled,
            mitmEnabled: engine.profile.general.mitmEnabled,
            certificateExists: FileManager.default.fileExists(atPath: engine.store.root.appendingPathComponent("ca/ca.pem").path),
            captureCount: engine.captures.count, captureCheck: capture, logs: LPLog.shared.snapshot(),
            managedLogs: engine.executionKernel == .mihomo ? engine.managedKernel.logs : "")
    }

    /// S2 的原地链路：host + policy → 一条精确规则 → 用新规则重测同一个主机，全程留在「为什么」。
    ///
    /// 规则由 `RuleDraft` 生成（置顶、同 host+policy 去重），policy 来自用户选择而不是写死 DIRECT；
    /// 保存后立刻 `diagnose`，结果落在同一页的证据与报告里，不跳页、不重新输入。
    @discardableResult
    func submit(host: String, policy: String) -> Bool {
        guard !busy else {
            // 不静默失败：调用方（编辑器）会把这句话显示在原处，sheet 不关。
            message = "正在检查中；等这次检查结束再改规则。"
            return false
        }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = SiteTarget(trimmed) else {
            failed = true
            message = "「\(trimmed)」里没有可写规则的域名；请输入主机名或完整网址。"
            return false
        }
        let draft = RuleDraft(host: target.host, policy: policy, source: .manual)
        let snapshot = engine.profile
        let change = NetworkRuleChange(profile: snapshot, target: target, policy: policy)
        let existing = change.after == change.before
        do {
            if !existing {
                try engine.commitTaskRules(expected: snapshot, rules: change.after)
            }
        } catch {
            failed = true
            message = error.localizedDescription
            return false
        }
        // 规则已经在配置里时什么都没写：不要用一个 before == after 的空改动覆盖 receipt，
        // 否则「撤销上次规则修改」会谎称恢复，还会把上一次真实改动的撤销点挤掉（T-14 评审 B3）。
        if !existing {
            receipt = change
            applied = true
        }
        preview = nil
        task = .inspect(target)
        diagnose(target)
        failed = false
        message = existing
            ? "规则已存在：\(draft.rule.raw)；配置未改动，正在原地重测…"
            : "已添加 \(draft.rule.raw)；正在原地重测…"
        return true
    }

    func diagnose(_ target: SiteTarget) {
        guard !busy else { return }
        lastTarget = target
        busy = true; report = nil
        message = "正在检查规则、DNS、直连 GET 与代理 HEAD…"
        failed = false; evidence = []
        Task {
            let snapshot = engine.profile
            let state = engine.state
            let kernel = engine.executionKernel
            let port = engine.diagnosticProxyPort
            let startedAt = engine.stats.startedAt
            let home = try? HomeConnection.load(root: engine.store.root)
            var input = diagnosticInput()
            input.target = target.origin
            let route: String
            if port != nil, let explanation = try? await engine.controlExplain(host: target.host, port: Int(target.port)) {
                route = "\(explanation.policy) → \(explanation.outbound)" + (explanation.isBlocked ? " · 被分流规则拒绝" : "")
            } else {
                let decision = RuleEngine(profile: snapshot).decide(ConnectionMeta(host: target.host, port: target.port))
                route = "\(decision.policy) → \(decision.outbound.name)（离线预估，未加载外部规则集）"
            }
            evidence.append(TaskEvidence(title: port != nil ? "当前分流" : "已保存的分流", value: route))
            let dns: DNSTrace
            if port != nil, let current = try? await engine.controlDNSTrace(host: target.host) { dns = current }
            else { dns = await DNSResolver(config: snapshot.dns).trace(target.host) }
            evidence.append(TaskEvidence(title: "当前 DNS 检查", value: dns.error ?? dns.resolved.joined(separator: " · ")))
            async let direct = HTTPProbe.probe(target.origin, timeoutMs: 5000)
            let proxy: HTTPProbeResult?
            if let port { proxy = await ProxyPathProbe.probe(target.origin, port: port) }
            else { proxy = nil }
            let result = await direct
            evidence.append(TaskEvidence(title: "直连 GET", value: result.error ?? "HTTP \(result.statusCode ?? 0) · \(Int(result.elapsedMs)) ms"))
            evidence.append(TaskEvidence(title: "本地代理 HEAD", value: proxy.map { $0.error ?? "HTTP \($0.statusCode ?? 0) · \(Int($0.elapsedMs)) ms" } ?? "服务未运行，本次未测试代理路径"))
            guard engine.profile == snapshot, engine.state == state, engine.executionKernel == kernel,
                  engine.diagnosticProxyPort == port, engine.stats.startedAt == startedAt,
                  engine.systemProxyActive == input.systemProxyActive,
                  (try? HomeConnection.load(root: engine.store.root)) == home else {
                failed = true; message = "检查期间配置或服务发生变化，以上结果已过期，请重新检查。"
                busy = false; return
            }
            input.dns = dns; input.direct = result; input.proxy = proxy
            input.logs = LPLog.shared.snapshot()
            input.managedLogs = kernel == .mihomo ? engine.managedKernel.logs : ""
            input.date = Date()
            report = NetworkDiagnosticAnalyzer.analyze(input)
            failed = (report?.problemCount ?? 0) > 0
            message = "检查已完成。响应只代表本次请求；登录、完整页面和 Agent 任务仍需实际验证。"
            busy = false
        }
    }

    func applyDirect(_ target: SiteTarget) {
        guard !busy, let preview else { return }
        let change = NetworkRuleChange(profile: preview, target: target)
        do {
            try engine.commitTaskRules(expected: preview, rules: change.after)
            receipt = change
            applied = true
            failed = false
            message = "已为 \(target.host) 添加优先直连规则。仅新连接生效，可撤销；访问效果尚未验证。"
        } catch {
            failed = true
            message = error.localizedDescription
        }
    }

    func undo() {
        guard let receipt, !busy else { return }
        guard receipt.canUndo(in: engine.profile) else {
            failed = true
            message = "规则或当前配置已变化，无法安全撤销。请在分流规则中检查这次修改。"
            return
        }
        do {
            try engine.commitTaskRules(expected: engine.profile, rules: receipt.before)
            self.receipt = nil
            applied = false
            failed = false
            message = "已撤销上次规则修改，恢复原有分流。再次修改前，请重新查看计划。"
            // A new edit must get a fresh preview after undo.
            preview = nil
        } catch {
            failed = true
            message = error.localizedDescription
        }
    }

    var canApply: Bool { preview != nil && !applied && !busy }
}

@MainActor
struct NetworkTaskPanel: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var assistant: NetworkAssistantModel

    var body: some View {
        if let task = assistant.task {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.clipboard").foregroundStyle(LP.accent).accessibilityHidden(true)
                    Text(title(task)).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(assistant.busy ? "执行中" : assistant.applied ? "已应用" : "任务计划")
                        .font(LPFont.mono(11)).foregroundStyle(LP.textSecondary)
                }
                plan(task)
                if !assistant.evidence.isEmpty {
                    LPDivider()
                    ForEach(assistant.evidence) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).font(.system(size: 13, weight: .semibold))
                            Text(item.value).font(LPFont.mono(13)).textSelection(.enabled)
                                .foregroundStyle(LP.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let message = assistant.message {
                    HStack(alignment: .top, spacing: 8) {
                        if assistant.busy { ProgressView().controlSize(.small) }
                        else { Image(systemName: assistant.failed ? "exclamationmark.circle" : "checkmark.circle") }
                        Text(message).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(assistant.failed ? LP.danger : LP.textSecondary)
                    .accessibilityElement(children: .combine)
                }
                HStack(spacing: 10) {
                    action(task)
                    if assistant.receipt != nil {
                        Button("撤销上次规则修改") { assistant.undo() }
                            .buttonStyle(LPGhostButtonStyle()).disabled(assistant.busy)
                    }
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(LP.text)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LP.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(LP.stroke))
        }
    }

    private func title(_ task: NetworkTask) -> String {
        switch task {
        case .inspect(let target): return "检查 \(target.host) 为什么打不开"
        case .direct(let target): return "只让 \(target.host) 直连"
        case .connect: return "让网络按当前方案连接"
        case .privacy: return "减少广告和跟踪"
        case .importProfile: return "带入已有的网络配置"
        case .company: return "访问公司内网资源"
        case .shareService: return "限时分享本地服务"
        case .toolCredits: return "查看工具与开源作者"
        case .home: return "回到家庭网络资源"
        case .nas: return "访问局域网文件"
        case .ssh: return "连接到服务器"
        case .learn: return "为 App 安排网络"
        case .unsupported: return "补充一个明确的目标"
        }
    }

    @ViewBuilder private func plan(_ task: NetworkTask) -> some View {
        switch task {
        case .inspect(let target):
            steps(["解释这个网站命中的分流规则", "使用当前 DNS 配置解析域名", "向 \(target.origin) 发起直连 GET；服务运行时另测代理 HEAD，不携带原链接路径和参数"])
            caption("这是一次只读检查。测试会访问目标网站，不会更改配置或开启 HTTPS 解密。")
        case .direct(let target):
            steps(["作用范围：仅 \(target.host)，不含子域名；所有端口", "在当前配置最前面添加一条直连规则", "保留其他规则和现有连接，随时撤销本次修改"])
            DisclosureGroup("查看具体变更") {
                Text("+ DOMAIN,\(target.host),DIRECT\n写入当前配置并立即应用于新连接。\n不会移除广告过滤、DNS 拦截或接管未经过代理的 App。")
                    .font(LPFont.mono(13)).foregroundStyle(LP.textSecondary).textSelection(.enabled).padding(.top, 8)
            }.font(.system(size: 13))
        case .connect:
            steps(["启动本地网络服务", "成功后自动接入 macOS 系统代理", "失败时显示原因，保留重试入口"])
            caption("使用当前配置。仅支持系统代理的 App 会经过 Leapin；连接完成不代表所有网站都可访问。")
        case .privacy:
            steps(["查看当前广告与跟踪过滤是否开启", "管理过滤列表与网站例外", "遇到误拦截时只为目标网站添加例外"])
            caption("继续到过滤工作区完成设置。不会自动开启 HTTPS 解密。")
        case .importProfile:
            steps(["选择已有的 Clash、Surge 或 Leapin 配置文件", "自动识别格式并显示兼容性报告"])
            caption("先检查格式与内核兼容性，确认后才启用。失败时恢复原方案。")
        case .company:
            steps(["选择公司，绑定已有客户端、系统 VPN、浏览器入口或内网代理", "添加常用资源，只对列出的主机配置访问", "检查系统 DNS、服务端口与 Web 响应；登录由公司工具完成"])
        case .shareService:
            steps(["选择本机服务端口、访问范围和有效期", "预览后显式建立临时分享连接", "到期或手动停止自有连接"])
        case .toolCredits:
            caption("查看本机工具版本、原项目作者、文档与许可证。")
        case .home:
            steps(["首次使用选择 Tailscale 家庭设备及资源地址", "核对设备身份、连接状态与服务端口", "检查通过后打开资源；仅该主机优先直连"])
            caption("已绑定连接若暂停，会按原设置尝试恢复。首次登录在 Tailscale 客户端完成。")
        case .nas:
            steps(["进入设备工作区，扫描同一网络中的共享设备", "选择设备，再填写共享名称与凭据"])
            caption("发现设备使用 Bonjour；不需要先配置代理。")
        case .ssh:
            steps(["进入服务器工作区，指定地址与账号", "选择密码或密钥，建立终端连接"])
        case .learn:
            steps(["粘贴 App 名称，或拖入应用列表截图", "查看生成的规则建议，勾选后应用"])
            caption("当前是本地应用识别与建议生成，不是通用大模型 Agent。")
        case .unsupported:
            caption("本地助手目前支持具体网站检查、精确域名直连和常用任务引导。请输入网站，或使用下面的任务模板；复杂需求请打开专业工具。")
        }
    }

    @ViewBuilder private func action(_ task: NetworkTask) -> some View {
        switch task {
        case .inspect(let target):
            Button(assistant.evidence.isEmpty ? "开始检查" : "重新检查") { assistant.diagnose(target) }
                .buttonStyle(LPPrimaryButtonStyle()).disabled(assistant.busy)
        case .direct(let target):
            if assistant.applied {
                Button("检查这个网站") { assistant.prepare(target.origin) }.buttonStyle(LPGhostButtonStyle())
            } else {
                Button("应用这条规则") { assistant.applyDirect(target) }
                    .buttonStyle(LPPrimaryButtonStyle()).disabled(!assistant.canApply)
            }
        case .connect:
            Button(app.networkBusy ? "正在连接…" : "连接网络") { app.connectNetwork() }
                .buttonStyle(LPPrimaryButtonStyle()).disabled(app.networkBusy)
        case .privacy: destination("查看过滤与例外", .adblock)
        case .importProfile:
            Button("导入与检查配置…") { app.beginImport() }.buttonStyle(LPPrimaryButtonStyle())
        case .company:
            Button("打开公司内网") { app.showCompany = true }.buttonStyle(LPPrimaryButtonStyle())
        case .shareService:
            Button("预览分享范围") { app.networkToolPage = 0; app.showNetworkTools = true }.buttonStyle(LPPrimaryButtonStyle())
        case .toolCredits:
            Button("查看工具与致谢") { app.networkToolPage = 2; app.showNetworkTools = true }.buttonStyle(LPPrimaryButtonStyle())
        case .home:
            Button("回家") { app.openHome() }.buttonStyle(LPPrimaryButtonStyle()).disabled(app.home.busy || app.engine.configurationBusy)
        case .nas: destination("发现共享设备", .nas)
        case .ssh: destination("填写服务器地址", .ssh)
        case .learn: destination("添加 App 或截图", .learn)
        case .unsupported:
            Button("输入诊断目标") { assistant.input = "诊断 "; app.requestSearchFocus() }.buttonStyle(LPGhostButtonStyle())
        }
    }

    private func destination(_ title: String, _ section: AppModel.Section) -> some View {
        Button(title) { app.go(to: section) }.buttonStyle(LPPrimaryButtonStyle())
    }

    private func steps(_ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, text in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(format: "%02d", index + 1)).font(LPFont.mono(11)).foregroundStyle(LP.textTertiary)
                    Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(LP.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
}


@MainActor
struct DiagnosticsWorkspace: View {
    /// 同一套工作区在「为什么」里有两个投影：探测（只发起检查、看命中链与耗时）与
    /// 诊断（再加报告卡与导出）。一个视图、两个视图不要各写一套探针入口。
    enum Scope: String, Equatable {
        case probes, full
    }

    @EnvironmentObject private var app: AppModel
    @ObservedObject var assistant: NetworkAssistantModel
    var scope: Scope = .full
    /// 作为 tab 内嵌时不再画页面级大标题：外层已经写了「为什么」与 tab 名（T-11 的同一口径）。
    var embedded: Bool = false
    /// 这个实例是不是当前可见的 tab。
    ///
    /// WhyPage 把出现过的 tab 留在 ZStack 里（切 tab 不销毁），所以探测与诊断会同时挂载；
    /// 全局的「聚焦搜索框」请求只该落到看得见的那一个（T-14 评审 O1）。
    var isActive: Bool = true
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !embedded {
                    Text("检查一个目标，或调整一条规则。")
                        .font(LPFont.display(28, weight: .semibold)).foregroundStyle(LP.text)
                }
                // 本地检查的结果是一张报告卡，而探测 tab 不渲染报告卡：在这里留着入口
                // 只会让人点了看不到任何结果（T-14 评审 O2）。
                if scope == .full {
                    HStack(spacing: 12) {
                        Button("检查本地代理") { assistant.inspectLocal() }.buttonStyle(LPPrimaryButtonStyle()).disabled(assistant.busy)
                        Button("排查抓包与解密") { assistant.inspectLocal(capture: true) }.buttonStyle(LPGhostButtonStyle()).disabled(assistant.busy)
                        Text("本地检查不发起外部请求").font(.system(size: 13)).foregroundStyle(LP.textTertiary)
                    }
                }
                TaskComposer(assistant: assistant, focused: $focused)
                if assistant.task == nil, let message = assistant.message {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(assistant.failed ? LP.danger : LP.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NetworkTaskPanel(assistant: assistant)
                if scope == .probes {
                    Text("命中链、DNS trace 与直连 / 代理耗时都在上面；完整报告与重复请求检查在「诊断」tab。")
                        .font(.system(size: 13)).foregroundStyle(LP.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if scope == .full, let report = assistant.report {
                    // 没有可重测的 host（本地检查之后）就不给「重新检查」，否则是死键。
                    DiagnosticReportView(report: report, onRetest: retestAction)
                }
                if scope == .full {
                    HStack(spacing: 12) {
                        Button("网络活动与连接明细") { app.go(to: .activity) }.buttonStyle(LPGhostButtonStyle())
                        Button("抓包与 HTTPS 解密") { app.go(to: .capture) }.buttonStyle(LPGhostButtonStyle())
                        Button("导入与转换配置") { app.beginImport() }.buttonStyle(LPGhostButtonStyle())
                    }
                }
            }.pagePadding()
        }
        .onChange(of: app.searchFocusRequest) { _, _ in
            guard isActive else { return }
            focused = true
        }
    }

    /// 报告卡上的「重新检查」：用同一份工作区再测一次，不要求用户回到输入框。
    private func retest() {
        guard let target = assistant.lastTarget else { return }
        assistant.diagnose(target)
    }

    /// 没有可重测的主机（例如刚做完本地检查）时不把动作交给卡片：按钮不出现，也就没有死键。
    private var retestAction: (() -> Void)? {
        assistant.lastTarget == nil ? nil : { retest() }
    }
}

@MainActor
private struct TaskComposer: View {
    @ObservedObject var assistant: NetworkAssistantModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("任务类型", selection: $assistant.directMode) {
                Text("检查网站 / 其他需求").tag(false)
                Text("网站直连").tag(true)
            }
            .pickerStyle(.segmented).frame(maxWidth: 330).disabled(assistant.busy)
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 18)).foregroundStyle(LP.accent).accessibilityHidden(true)
                TextField(assistant.directMode ? "输入需要直连的网站域名" : "输入网站，或任务：访问家里的文件", text: $assistant.input)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused(focused).onSubmit { assistant.submit() }
                    .accessibilityLabel("网站或网络需求")
                    .disabled(assistant.busy)
                Group {
                    if assistant.task == nil {
                        Button("查看计划") { assistant.submit() }.buttonStyle(LPPrimaryButtonStyle())
                    } else {
                        Button("更新计划") { assistant.submit() }.buttonStyle(LPGhostButtonStyle())
                    }
                }
                    .disabled(assistant.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.busy)
            }
            LPDivider()
            Text("本地任务助手 · 输入 example.com 检查网站，或输入「让 example.com 直连」预览规则。")
                .font(.system(size: 13)).foregroundStyle(LP.textSecondary).fixedSize(horizontal: false, vertical: true)
            if assistant.receipt != nil, assistant.task == nil {
                Button("撤销上次规则修改") { assistant.undo() }.buttonStyle(LPGhostButtonStyle())
            }
        }
        .padding(20).lpPanel(padding: 0)
    }
}
