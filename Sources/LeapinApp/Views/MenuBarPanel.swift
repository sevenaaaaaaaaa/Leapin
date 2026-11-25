import SwiftUI
import AppKit
import LeapinCore
import LeapinControl
import LeapinRuntime
import LeapinIntegrations

/// 常驻层的主体（PRODUCT-v4 §2.1）。
///
/// 三块 + footer，只允许三种动作：**看**（现在走哪条路）、**切**（配置 / 场景 /
/// 节点）、**跳**（窗口里的对应页面）。常驻面一旦能装下四个动词，它就退化成第二个
/// 窗口（§6 风险 3），所以完整节点表、端口编辑、页面导航都不在这里：节点只留当前
/// 策略组的那几项，端口与导航各留一行入口；系统代理与浮窗本来就是**开关**，就地
/// 切换才叫一步到达（DoD 4）。
///
/// 所有数字来自 `ResidentStatusStore`，与实时浮窗读同一份；这个视图不再自己
/// 采样字节、也不再自己算速率。
@MainActor
struct MenuBarPanel: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var floating = FloatingPanelController.shared
    @ObservedObject private var resident = ResidentStatusStore.shared

    @State private var snapshot: MenuBarSnapshot?
    @State private var report: PortReport?
    @State private var actionError: String?
    /// 系统代理正在切：双击会并发两次 networksetup，所以动作期间把 chip 禁用。
    @State private var togglingProxy = false

    private var engine: LeapinEngine { app.engine }
    private var status: ResidentStatus { resident.status }
    private var profiles: [MenuBarProfile] { snapshot?.profiles ?? [] }
    /// 面板自己能切的策略组；url-test / fallback 自己选，不列进来。
    private var nodeGroups: [MenuBarGroup] { snapshot?.nodeMenuGroups ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            nowCard
            switchCard
            if showsIssues { issueCard }
            footer
        }
        .padding(14)
        .frame(width: 280)
        .task { await liveLoop() }
        .onChange(of: engine.state.label) { _, _ in Task { await refresh() } }
        .onChange(of: engine.profile.id) { _, _ in Task { await refresh() } }
    }

    // MARK: 现在

    private var nowCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            LPEyebrow("现在")

            HStack(spacing: 6) {
                StatusDot(color: status.tone.ink, pulsing: engine.state == .running)
                Text(status.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(LP.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(latencyText)
                    .font(LPFont.mono(10.5, weight: .semibold))
                    .foregroundStyle(latencyColor)
            }

            // v6：同一「路」，第三条腿可以拖。松手才提交，候选在下方浮出。
            LPRouteScrubber(
                stops: menuStops,
                selectedID: status.exit ?? "—",
                judge: judgeShort,
                enabled: engine.state == .running && menuStops.count > 1,
                compact: true
            ) { member in
                if let group = currentNodeGroup {
                    select(group: group.name, member: member)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(engine.state == .running ? "按住出口上下拖，松手生效" : "未接管：没有可切换的出口")

            factRow("配置", status.profileName.isEmpty ? "—" : status.profileName)
            factRow("出口", exitText)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                rate("arrow.down", status.rates.downText)
                rate("arrow.up", status.rates.upText)
                Spacer(minLength: 6)
                Text("拦截 \(status.blocked)")
                    .font(LPFont.num(10, weight: .medium))
                    .foregroundStyle(status.blocked > 0 ? LP.text : LP.textTertiary)
            }

            // §2.5 的一行事实：撞上去之前就知道，不写在免责声明里。
            Text(status.coverage.declaration)
                .font(.system(size: 11))
                .foregroundStyle(LP.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                app.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: engine.state == .running ? "stop.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(engine.state == .running ? "停止代理" : "启动代理")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LPPrimaryButtonStyle(tint: engine.state == .running ? LP.dangerFill : nil))
            .help(engine.state == .running ? "断开本地服务并恢复系统代理" : "启动本地服务并接入系统代理")

            entries
        }
        .padding(10)
        .background(LP.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// 缩略里只放能一眼扫完的词：未接管就说未接管，别把一句状态文案塞进 280pt。
    /// 菜单栏能拖的那个组：优先「现在」正在用的组，否则第一个可切换组。
    private var currentNodeGroup: MenuBarGroup? {
        guard !nodeGroups.isEmpty else { return nil }
        if let name = status.exitGroup, let hit = nodeGroups.first(where: { $0.name == name }) {
            return hit
        }
        return nodeGroups.first
    }

    private var menuStops: [LPRouteScrubber.Stop] {
        guard let group = currentNodeGroup else { return [] }
        return group.members.map { node in
            LPRouteScrubber.Stop(
                id: node.name,
                label: node.name,
                detail: node.failed ? "失败" : (node.latencyMs.map { "\($0)ms" } ?? "")
            )
        }
    }

    private var judgeShort: String {
        guard engine.state == .running else { return "尚未接管" }
        return status.exitGroup ?? "规则模式"
    }

    private var exitShort: String {
        guard engine.state == .running, let exit = status.exit else { return "—" }
        return exit
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(LP.textTertiary)
                .frame(width: 26, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(LP.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func rate(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(engine.state == .running ? LP.accent : LP.textTertiary)
            Text(text)
                .font(LPFont.num(10.5, weight: .semibold))
                .foregroundStyle(LP.text)
                .monospacedDigit()
        }
    }

    /// 被收掉的能力各留一行入口：一步到达窗口里做这件事的地方。
    private var entries: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                chip("端口 \(engine.profile.general.mixedPort)", help: "在设置里改监听端口") { open(.settings) }
                // 测速还在线路与订阅页：常驻面不留测速按钮，但必须留一步到得了的入口。
                chip("线路与订阅", help: "在线路与订阅里测速、换订阅") { open(.profiles) }
                // 系统代理是开关，不是导航：点一下就地切，别把人送去总览再自己找。
                // 引擎没跑时开启必失败（enableSystemProxy 要求 running），所以先禁用。
                chip(engine.systemProxyActive ? "接管 开" : "接管 关",
                     help: takeoverHelp,
                     disabled: takeoverDisabled) {
                    togglingProxy = true
                    Task {
                        defer { togglingProxy = false }
                        await engine.toggleSystemProxy(!engine.systemProxyActive)
                        await refresh()
                    }
                }
                chip(floating.isVisible ? "浮窗 开" : "浮窗 关",
                     help: floating.isVisible ? "隐藏实时浮窗" : "显示实时浮窗") {
                    toggleFloating()
                }
            }
            HStack(spacing: 5) {
                ForEach([AppModel.Section.dashboard, .rules, .capture, .settings]) { section in
                    chip(section.title, help: "打开\(section.title)") { open(section) }
                }
            }
        }
        .padding(.top, 1)
    }

    /// 引擎没跑时开不了系统代理（enableSystemProxy 要求 state == .running），
    /// 切换配置期间也不该动它：两种情况下 chip 直接禁用，别让人点了必失败。
    private var takeoverDisabled: Bool {
        togglingProxy || engine.configurationBusy
            || (!engine.systemProxyActive && engine.state != .running)
    }

    private var takeoverHelp: String {
        if !engine.systemProxyActive && engine.state != .running { return "先启动代理" }
        return engine.systemProxyActive ? "点一下关闭系统代理" : "点一下开启系统代理"
    }

    private func chip(_ title: String, help: String, disabled: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LP.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(LP.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel("\(title)，\(help)")
    }

    // MARK: 切换

    private var switchCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            LPEyebrow("切换")

            Menu {
                ForEach(profiles) { item in
                    Button {
                        switchProfile(item.id)
                    } label: {
                        Text(item.id == snapshot?.activeProfile ? "✓ \(item.name)" : item.name)
                    }
                }
                if profiles.isEmpty { Text("还没有导入订阅") }
            } label: {
                MenuBarRowLabel(icon: "tray.full", title: "配置", value: activeProfileName)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(profiles.count <= 1 || engine.configurationBusy)
            .help("切换到另一份配置；失败会留在原配置")

            Menu {
                ForEach(NetworkScene.allCases) { scene in
                    Button {
                        app.switchScene(scene)
                    } label: {
                        Text(sceneLabel(scene))
                    }
                }
            } label: {
                MenuBarRowLabel(icon: "square.grid.2x2", title: "场景", value: activeSceneName)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(app.networkBusy || engine.configurationBusy)
            .help("切换场景会同时换掉它绑定的配置")

            // 节点切换只能在这里做：线路页只负责看和测速，原生内核下切节点等于没入口。
            Menu {
                ForEach(nodeGroups) { group in
                    Menu {
                        ForEach(group.members) { member in
                            Button {
                                select(group: group.name, member: member.name)
                            } label: {
                                Text(nodeLabel(member, selected: group.selected == member.name))
                            }
                        }
                    } label: {
                        Text("\(group.name) · \(group.selected)")
                    }
                }
                if nodeGroups.isEmpty { Text("这份配置没有可切换的策略组") }
            } label: {
                MenuBarRowLabel(icon: "point.3.connected.trianglepath.dotted", title: "节点", value: nodeMenuValue)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(nodeGroups.isEmpty || engine.configurationBusy)
            .help("切换策略组里的节点；失败会留在原节点")
        }
        .padding(10)
        .background(LP.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var activeProfileName: String {
        profiles.first { $0.id == snapshot?.activeProfile }?.name ?? engine.profile.name
    }

    private var activeSceneName: String {
        guard let active = app.scenes.active else { return "未选择" }
        return active.title
    }

    private func sceneLabel(_ scene: NetworkScene) -> String {
        guard let id = app.scenes.profileID(for: scene) else { return "\(scene.title) · 未绑定" }
        let name = profiles.first { $0.id == id }?.name ?? "已绑定配置"
        let mark = app.scenes.active == scene ? "✓ " : ""
        return "\(mark)\(scene.title) · \(name)"
    }

    /// 没跑起来时没有「当前节点」可讲，说未运行比说破折号诚实。
    private var nodeMenuValue: String {
        guard engine.state == .running else { return "未运行" }
        return snapshot?.current ?? "—"
    }

    /// 菜单里的一行节点：勾 + 名字 + 延迟；不可拨的节点不报延迟。
    private func nodeLabel(_ node: MenuBarNode, selected: Bool) -> String {
        let mark = selected ? "✓ " : ""
        let latency = node.dialable ? " · \(MenuBarKit.latencyText(node.latencyMs, failed: node.failed))" : ""
        return mark + node.name + latency
    }

    // MARK: 异常（没有错误、没有降级时不渲染）

    private var showsIssues: Bool {
        !status.issues.isEmpty || !portIssues.isEmpty || !actionIssues.isEmpty
    }

    private var issueCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            LPEyebrow("异常", tint: LP.danger)
            ForEach(status.issues) { issue in
                issueRow(issue)
            }
            ForEach(portIssues) { issue in
                issueRow(issue)
            }
            ForEach(actionIssues) { issue in
                // 动作失败是「上一次点了什么」的结果，只有它能被用户关掉；
                // 引擎/端口那些状态项不给 ×，否则等于让用户把故障藏起来。
                issueRow(issue, dismissible: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LP.danger.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// 端口占用、别的内核在抢流量、lsof 不可用：都是面板自己取得到、常驻状态里不该有的东西。
    private var portIssues: [ResidentIssue] {
        var issues: [ResidentIssue] = []
        for conflict in report?.conflicts ?? [] {
            issues.append(.init(severity: .degraded, text: conflict.summary))
        }
        // 只有 Mihomo 模式才值得提：那是第二个内核和我们在抢同一份流量。
        if engine.executionKernel == .mihomo, let note = report?.foreignKernelNote {
            issues.append(.init(severity: .degraded, text: note))
        }
        if report?.auditFailed == true {
            issues.append(.init(severity: .degraded, text: "端口检查不可用（lsof 未返回结果），占用情况未知"))
        }
        return issues
    }

    /// 面板自己发起的动作失败（切节点）：错误得留在面板上，否则点完没反应。
    private var actionIssues: [ResidentIssue] {
        guard let actionError else { return [] }
        return [.init(severity: .degraded, text: actionError)]
    }

    private func issueRow(_ issue: ResidentIssue, dismissible: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: issue.severity == .failure
                  ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                .font(.system(size: 11))
                .padding(.top, 1)
            Text(issue.text)
                .lineLimit(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if dismissible {
                Button {
                    actionError = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.top, 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关掉这条提示")
                .accessibilityLabel("关掉这条提示")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(issue.severity == .failure ? LP.danger : LP.amber)
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    app.showPalette = true
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack(spacing: 5) {
                        Text("命令面板").font(.system(size: 11))
                        Spacer(minLength: 0)
                        LPKeyCap(keys: "⌘K")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    toggleFloating()
                } label: {
                    Text(floating.isVisible ? "收起浮窗" : "实时浮窗")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LP.textSecondary)
            }

            HStack(spacing: 6) {
                Button("打开主窗口") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                Spacer(minLength: 0)
                Button("退出 Leapin") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(LP.textSecondary)
            }
        }
    }

    // MARK: 取值

    private var exitText: String {
        guard engine.state == .running else { return "—" }
        guard let exit = status.exit else { return "没有可切换的节点" }
        let group = status.exitGroup.map { "\($0) › " } ?? ""
        return group + exit
    }

    private var latencyText: String {
        guard engine.state == .running else { return "—" }
        return MenuBarKit.latencyText(snapshot?.currentLatencyMs)
    }

    private var latencyColor: Color {
        switch LatencyTone.of(snapshot?.currentLatencyMs) {
        case .fast: return LP.mint
        case .ok: return LP.amber
        case .slow, .failed: return LP.danger
        case .unknown: return LP.textTertiary
        }
    }

    // MARK: 动作

    /// 面板打开期间按 1 Hz 喂帧；视图消失（面板收起）循环就结束。
    /// 采样驱动放在视图里，`ResidentStatusStore` 自己不持有任何定时器。
    ///
    /// 只喂帧，不再顺带 refresh()：快照（mihomo 要打内核 HTTP）和端口审计
    /// （每次真起 lsof / pgrep / ps，lsof 超时 4s）都不是 1 Hz 该做的事，
    /// 它们只在打开、状态 / 配置变化、动作成功后各取一次。
    private func liveLoop() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            resident.update(from: engine, at: Date())
        }
    }

    private func refresh() async {
        let latest = await engine.menuBarSnapshot()
        snapshot = latest
        report = await engine.portReport()
        resident.update(from: engine, snapshot: latest)
        // 图标上的延迟数字继续吃探针的结果：面板不再自带测速按钮，徽标不能因此失声。
        if let current = latest.current, let latency = latest.currentLatencyMs {
            MenuBarStatus.shared.current = MenuBarTestOutcome(name: current, latencyMs: latency)
        }
        // 这里不清 actionError：切配置失败会回滚 profile.id，那次变更正好触发一次
        // refresh，把刚设上的错误立刻抹掉。错误只由「下一次动作开始」「动作成功」
        // 和「用户点 ×」三处清。
    }

    private func toggleFloating() {
        if floating.isVisible { floating.hide() } else { floating.show() }
    }

    private func open(_ section: AppModel.Section) {
        app.go(to: section)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 切一个策略组的成员。失败留在面板上（进「异常」块），不往控制台丢。
    private func select(group: String, member: String) {
        actionError = nil
        Task {
            do {
                try await engine.menuBarSelect(group: group, member: member)
                await refresh()
            } catch {
                actionError = Redactor.redact(error.localizedDescription)
            }
        }
    }

    private func switchProfile(_ id: UUID) {
        actionError = nil
        Task {
            await engine.menuBarSwitch(profile: id)
            // activate 失败会回滚到原配置、只写 lastError：先确认真的切过去了再改场景，
            // 否则「配置」说 A、「场景」说 B，两个菜单互相打脸。
            guard engine.profile.id == id else {
                actionError = Redactor.redact(engine.lastError ?? "切换配置失败")
                return
            }
            // 配置换了，场景也要跟着改口：否则「现在」说 A，场景菜单还说 B。
            if let scene = NetworkScene.allCases.first(where: { app.scenes.profileID(for: $0) == id }) {
                try? app.scenes.markActive(scene)
            }
            await refresh()
        }
    }
}

/// 常驻面的 ink：墨（正常）/ 半红（降级）/ 红（异常）。面板与浮窗共用这一份，
/// 因此同一个 tone 在两个面上不会画出两种颜色。
extension ResidentTone {
    var ink: Color {
        switch self {
        case .idle: return LP.textTertiary
        case .normal: return LP.mint
        case .degraded: return LP.amber
        case .failed: return LP.danger
        }
    }
}

/// 切换块的一行：图标 + 名字 + 当前值 + 下拉提示。
struct MenuBarRowLabel: View {
    var icon: String
    var title: String
    var value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).frame(width: 13)
                .foregroundStyle(LP.textTertiary)
            Text(title).font(.system(size: 11))
            Spacer(minLength: 6)
            Text(value).font(.system(size: 11))
                .foregroundStyle(LP.textSecondary)
                .lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
                .foregroundStyle(LP.textTertiary)
        }
        .foregroundStyle(LP.text)
        .contentShape(Rectangle())
    }
}
