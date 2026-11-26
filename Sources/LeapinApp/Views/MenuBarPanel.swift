import SwiftUI
import AppKit
import LeapinCore
import LeapinControl
import LeapinRuntime
import LeapinIntegrations

/// 常驻层的主体（PRODUCT-v4 §2.1）。
///
/// 只允许三种动作：**看**（现在走哪条路）、**切**（配置 / 场景 / 节点）、**跳**（窗口里的
/// 对应页面）。常驻面一旦能装下四个动词，它就退化成第二个窗口（§6 风险 3），所以完整
/// 节点表、端口编辑、页面导航都不在这里：节点只留当前策略组的那几项，页面各留一格。
///
/// 自上而下就是这三件事的顺序：一条路（看）→ 三行可切的（切）→ 一条页面导轨（跳）。
/// 以前这里是三张小卡加两排 chip，「接管」「浮窗」「端口」各占一枚，和主按钮一样重。
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
    /// 60 秒速率河，1 Hz 一帧，和首屏是同一条河的矮条形态。
    @State private var river: [LPRiverSample] = Array(repeating: .zero, count: 60)

    private var engine: LeapinEngine { app.engine }
    private var status: ResidentStatus { resident.status }
    private var profiles: [MenuBarProfile] { snapshot?.profiles ?? [] }
    /// 面板自己能切的策略组；url-test / fallback 自己选，不列进来。
    private var nodeGroups: [MenuBarGroup] { snapshot?.nodeMenuGroups ?? [] }
    private var running: Bool { engine.state == .running }
    private var connected: Bool { running && engine.systemProxyActive }
    private var takeoverBusy: Bool { app.networkBusy || engine.configurationBusy || engine.state == .starting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            route
                .padding(.top, 12)
            if running {
                LPRiver(samples: river, frozenIndex: nil, enabled: true,
                        onInk: false, height: 20, showsIdleHint: false) { _ in }
                    .padding(.top, 10)
                // 没在跑就没有「此刻的速率」：不摆一排 0。
                ratesRow
                    .padding(.top, 8)
            }
            if showsIssues {
                rule
                issueList
            }
            rule
            switchRows
            rule
            actionRow
            pageRail
                .padding(.top, 10)
            utilityRow
                .padding(.top, 8)
            // §2.5 的一行事实：撞上去之前就知道，不写在免责声明里。
            Text(status.coverage.declaration)
                .font(.system(size: 11))
                .foregroundStyle(LP.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 280)
        .task { await liveLoop() }
        .onChange(of: engine.state.label) { _, _ in Task { await refresh() } }
        .onChange(of: engine.profile.id) { _, _ in Task { await refresh() } }
        .onChange(of: engine.systemProxyActive) { _, _ in Task { await refresh() } }
    }

    // MARK: 看：现在

    /// 状态一行。store 还没喂过第一帧时它没有标题，那一刻先说引擎自己的状态。
    private var header: some View {
        HStack(spacing: 7) {
            StatusDot(color: status.tone.ink, pulsing: running)
            Text(status.title.isEmpty ? engine.state.label : status.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LP.text)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(latencyText)
                .font(LPFont.mono(11, weight: .semibold))
                .foregroundStyle(latencyColor)
        }
        .accessibilityElement(children: .combine)
    }

    /// 同一条「路」，第三站可以拖。松手才提交，候选在下方浮出。
    private var route: some View {
        VStack(alignment: .leading, spacing: 6) {
            LPRouteScrubber(
                stops: menuStops,
                selectedID: status.exit ?? menuStops.first?.id ?? "",
                judge: judgeShort,
                enabled: running && menuStops.count > 1,
                size: .compact
            ) { member in
                if let group = currentNodeGroup {
                    select(group: group.name, member: member)
                }
            }
            Text(status.profileName.isEmpty ? "还没有导入配置" : status.profileName)
                .font(.system(size: 12))
                .foregroundStyle(LP.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(running ? "按住出口上下拖，松手生效" : "未接管：没有可切换的出口")
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
                detail: node.failed ? "失败" : (node.latencyMs.map { "\($0) ms" } ?? "")
            )
        }
    }

    private var judgeShort: String {
        guard running else { return "尚未接管" }
        return status.exitGroup ?? "规则模式"
    }

    private var ratesRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            rate("arrow.down", status.rates.downText)
            rate("arrow.up", status.rates.upText)
            Spacer(minLength: 6)
            Text("拦截 \(status.blocked)")
                .font(LPFont.num(11, weight: .medium))
                .foregroundStyle(status.blocked > 0 ? LP.text : LP.textTertiary)
        }
    }

    private func rate(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(running ? LP.accent : LP.textTertiary)
            Text(text)
                .font(LPFont.num(13, weight: .semibold))
                .foregroundStyle(LP.text)
                .monospacedDigit()
        }
    }

    // MARK: 切：三行

    private var switchRows: some View {
        VStack(spacing: 0) {
            LPPopUpRow(title: "配置", value: activeProfileName,
                       enabled: profiles.count > 1 && !engine.configurationBusy,
                       help: "切换到另一份配置；失败会留在原配置",
                       menu: profileMenu)

            LPPopUpRow(title: "场景", value: activeSceneName,
                       enabled: !app.networkBusy && !engine.configurationBusy,
                       help: "切换场景会同时换掉它绑定的配置",
                       menu: sceneMenu)

            // 节点切换只能在这里做：线路页只负责看和测速，原生内核下切节点等于没入口。
            LPPopUpRow(title: "节点", value: nodeMenuValue,
                       enabled: !nodeGroups.isEmpty && !engine.configurationBusy,
                       help: "切换策略组里的节点；失败会留在原节点",
                       menu: nodeMenu)
        }
    }

    private func profileMenu() -> [LPPopUpItem] {
        if profiles.isEmpty { return [.note("还没有导入订阅")] }
        return profiles.map { item in
            .item(item.name, selected: item.id == snapshot?.activeProfile) { switchProfile(item.id) }
        }
    }

    private func sceneMenu() -> [LPPopUpItem] {
        NetworkScene.allCases.map { scene in
            .item(sceneLabel(scene), selected: app.scenes.active == scene) { app.switchScene(scene) }
        }
    }

    private func nodeMenu() -> [LPPopUpItem] {
        if nodeGroups.isEmpty { return [.note("这份配置没有可切换的策略组")] }
        return nodeGroups.map { group in
            .submenu("\(group.name) · \(group.selected)", group.members.map { member in
                .item(nodeLabel(member, selected: group.selected == member.name)) {
                    select(group: group.name, member: member.name)
                }
            })
        }
    }

    private var activeProfileName: String {
        profiles.first { $0.id == snapshot?.activeProfile }?.name ?? engine.profile.name
    }

    private var activeSceneName: String {
        guard let active = app.scenes.active else { return "未选择" }
        return active.title
    }

    /// 勾选交给菜单自己的对勾列（`selected`），标题里不再手写「✓ 」。
    private func sceneLabel(_ scene: NetworkScene) -> String {
        guard let id = app.scenes.profileID(for: scene) else { return "\(scene.title) · 未绑定" }
        let name = profiles.first { $0.id == id }?.name ?? "已绑定配置"
        return "\(scene.title) · \(name)"
    }

    /// 没跑起来时没有「当前节点」可讲，说未运行比说破折号诚实。
    private var nodeMenuValue: String {
        guard running else { return "未运行" }
        return snapshot?.current ?? "—"
    }

    /// 菜单里的一行节点：名字 + 延迟；不可拨的节点不报延迟。
    private func nodeLabel(_ node: MenuBarNode, selected: Bool) -> String {
        let latency = node.dialable ? " · \(MenuBarKit.latencyText(node.latencyMs, failed: node.failed))" : ""
        return node.name + latency
    }

    // MARK: 异常（没有错误、没有降级时不渲染）

    private var showsIssues: Bool {
        !status.issues.isEmpty || !portIssues.isEmpty || !actionIssues.isEmpty
    }

    /// 一句一事，颜色只在一个点和一行字上；引擎和端口的异常不给 ×，否则等于让人把故障藏起来。
    private var issueList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(status.issues + portIssues) { issue in
                issueRow(issue)
            }
            ForEach(actionIssues) { issue in
                // 动作失败是「上一次点了什么」的结果，只有它能被用户关掉。
                HStack(alignment: .top, spacing: 6) {
                    issueRow(issue)
                    Button {
                        actionError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(LP.textTertiary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("关掉这条提示")
                    .accessibilityLabel("关掉这条提示")
                }
            }
        }
    }

    private func issueRow(_ issue: ResidentIssue) -> some View {
        let color = issue.severity == .failure ? LP.danger : LP.amber
        return HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            Text(issue.text)
                .font(.system(size: 12))
                .foregroundStyle(LP.text)
                .lineLimit(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(issue.severity == .failure ? "异常" : "降级")：\(issue.text)")
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

    // MARK: 动作

    /// 主按钮只做一件事：让系统流量经过 Leapin（或停止经过）。它和页头那枚胶囊是同一个开关。
    /// 「只起本地服务、不接管」是给手动配置代理的人的，收在右边一个不抢眼的入口里。
    private var actionRow: some View {
        HStack(spacing: 10) {
            if connected {
                Button("暂停接管") {
                    Task {
                        await app.pauseNetwork()
                        await refresh()
                    }
                }
                .buttonStyle(LPGhostButtonStyle())
            } else {
                Button(takeoverTitle) {
                    app.connectNetwork()
                }
                .buttonStyle(LPPrimaryButtonStyle())
                .disabled(takeoverBusy)
            }
            Spacer(minLength: 6)
            Button(engine.state == .running ? "停止服务" : "只起服务") {
                actionError = nil
                Task {
                    if engine.state == .running { engine.stop() } else { await engine.start() }
                    await refresh()
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(engine.state == .running ? LP.danger : LP.textSecondary)
            .disabled(engine.configurationBusy || engine.state == .starting)
            .help(engine.state == .running
                  ? "只停止本地服务；如果已经接管，系统代理会同时恢复"
                  : "只启动本地服务，不接入系统代理")
            .accessibilityLabel(engine.state == .running ? "只停止本地服务" : "只启动本地服务")
        }
    }

    private var takeoverTitle: String {
        if app.networkBusy { return "接管中…" }
        return running ? "接管网络" : "连接网络"
    }

    // MARK: 跳：页面导轨

    /// 四格和首屏的场景导轨是同一种控件：它是一个选择器，不是四枚按钮。
    private var pageRail: some View {
        let pages: [AppModel.Section] = [.dashboard, .rules, .why, .settings]
        return HStack(spacing: 0) {
            ForEach(Array(pages.enumerated()), id: \.offset) { offset, section in
                Button {
                    open(section)
                } label: {
                    Text(section.headerTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LP.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开主窗口里的「\(section.headerTitle)」")
                if offset < pages.count - 1 {
                    Rectangle().fill(LP.line).frame(width: 1, height: 14)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
                .fill(LP.sheet)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous)
                .strokeBorder(LP.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: LPRadius.control, style: .continuous))
    }

    private var utilityRow: some View {
        HStack(spacing: 12) {
            Button {
                app.showPalette = true
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack(spacing: 4) {
                    Text("命令面板")
                    Image(systemName: "command")
                        .font(.system(size: 9, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .help("命令面板（⌘K）")

            Button {
                toggleFloating()
            } label: {
                Text(floating.isVisible ? "收起浮窗" : "浮窗")
                    .contentShape(Rectangle())
            }
            .help(floating.isVisible ? "隐藏实时浮窗" : "显示实时浮窗")

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("主窗口")
                    .contentShape(Rectangle())
            }

            Spacer(minLength: 0)

            Button("退出") { NSApp.terminate(nil) }
                .foregroundStyle(LP.textTertiary)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(LP.textSecondary)
    }

    // MARK: 取值

    private var latencyText: String {
        guard running else { return "—" }
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

    private var rule: some View {
        Rectangle().fill(LP.line).frame(height: 1).padding(.vertical, 10)
    }

    // MARK: 取数

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
            // 河只读 store 已经算好的速率，自己不做第二次差分。
            river.removeFirst()
            river.append(LPRiverSample(down: normalize(status.rates.down), up: normalize(status.rates.up)))
        }
    }

    /// 对数归一：1 KB/s 看得见，3 MB/s 封顶。与首屏同一条曲线。
    private func normalize(_ bytesPerSecond: Double) -> Double {
        guard bytesPerSecond > 0 else { return 0 }
        return min(1, log1p(bytesPerSecond) / log1p(3_000_000))
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

    // MARK: 动作

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
