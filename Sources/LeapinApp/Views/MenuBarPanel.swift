import SwiftUI
import AppKit
import LeapinCore
import LeapinControl
import LeapinRuntime
import LeapinIntegrations

/// The menu bar is where the daily switching happens, so it carries the two
/// things Surge/ClashX users reach for: a latency test and a node/airport switch.
/// In Mihomo mode both go through the kernel's own API — the app's dialer cannot
/// speak clash protocols, and a greyed-out test is the bug this replaces.
@MainActor
struct MenuBarPanel: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var floating = FloatingPanelController.shared
    @ObservedObject private var status = MenuBarStatus.shared

    @State private var snapshot: MenuBarSnapshot?
    @State private var report: PortReport?
    @State private var quick: MenuBarTestOutcome?
    @State private var summary: MenuBarTestSummary?
    @State private var testingOne = false
    @State private var testingAll = false
    @State private var progress = (done: 0, total: 0)
    @State private var query = ""
    @State private var actionError: String?

    private var engine: LeapinEngine { app.engine }
    private var totalMembers: Int { snapshot?.nodeMenuGroups.reduce(0) { $0 + $1.members.count } ?? 0 }
    private var profiles: [MenuBarProfile] { snapshot?.profiles ?? [] }
    private var switchable: [MenuBarGroup] { snapshot?.nodeMenuGroups ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            startStop
            speedCard
            switchCard
            toggles
            metrics
            address
            issues
            LPDivider()
            navigation
            LPDivider()
            footer
        }
        .padding(14)
        .frame(width: 262)
        .task { await refresh() }
        .onChange(of: engine.state.label) { _, _ in Task { await refresh() } }
        .onChange(of: app.engine.profile.id) { _, _ in Task { await refresh() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(LP.accentFill)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text("Leapin").font(LPFont.display(12.5, weight: .bold))
                Text(subtitle).font(.system(size: 9)).foregroundStyle(LP.textTertiary).lineLimit(1)
            }
            Spacer()
            StatusDot(color: engine.state == .running ? LP.mint : LP.textTertiary,
                      pulsing: engine.state == .running)
        }
    }

    private var subtitle: String {
        guard engine.state == .running else { return engine.state.label }
        return snapshot.map { MenuBarKit.modeTitle($0.mode) } ?? engine.state.label
    }

    // MARK: Start / stop

    private var startStop: some View {
        Button {
            app.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: engine.state == .running ? "stop.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(engine.state == .running ? "停止代理" : "启动代理")
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LPPrimaryButtonStyle(tint: engine.state == .running ? LP.dangerFill : nil))
    }

    // MARK: M3 — quick test

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 7) {
                Circle().fill(currentToneColor).frame(width: 6, height: 6)
                Text(currentLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LP.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(MenuBarKit.latencyText(currentLatency, failed: quick?.error != nil && currentLatency == nil))
                    .font(LPFont.mono(11, weight: .semibold))
                    .foregroundStyle(currentToneColor)
            }
            HStack(spacing: 6) {
                Button {
                    quickTest()
                } label: {
                    HStack(spacing: 4) {
                        if testingOne { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold)) }
                        Text("快速测速").font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(LPGhostButtonStyle())
                .disabled(testingOne || testingAll || engine.state != .running)
                .help("测试当前节点的延迟")

                Button {
                    testAll()
                } label: {
                    HStack(spacing: 4) {
                        if testingAll { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "list.bullet").font(.system(size: 9, weight: .semibold)) }
                        Text("全部测速").font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(LPGhostButtonStyle())
                .disabled(testingOne || testingAll || engine.state != .running)
                .help("测试全部节点并找出最快的一个")
            }
            if testingAll, progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .controlSize(.mini)
                Text("已测 \(progress.done)/\(progress.total)")
                    .font(.system(size: 9.5)).foregroundStyle(LP.textTertiary)
            }
            if let line = resultLine {
                Text(line)
                    .font(.system(size: 10))
                    .foregroundStyle(failureLine ? LP.danger : LP.textSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(LP.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var failureLine: Bool { quick?.error != nil || summary?.error != nil }

    private var engineFailure: String? {
        guard case .failed = engine.state else { return nil }
        return engine.lastError ?? engine.state.label
    }

    private var currentLabel: String {
        guard engine.state == .running else { return "代理未运行" }
        if let name = snapshot?.current { return name }
        return snapshot?.note ?? "没有可用的节点"
    }

    private var currentLatency: Int? {
        quick?.latencyMs ?? snapshot?.currentLatencyMs ?? status.best?.latencyMs
    }

    private var currentToneColor: Color {
        switch LatencyTone.of(currentLatency, failed: quick?.error != nil) {
        case .fast: return LP.mint
        case .ok: return LP.amber
        case .slow, .failed: return LP.danger
        case .unknown: return LP.textTertiary
        }
    }

    private var resultLine: String? {
        if let error = quick?.error { return "测速失败：\(error)" }
        if let error = summary?.error { return "全部测速失败：\(error)" }
        guard let summary, summary.tested > 0 else { return nil }
        var parts = ["测完 \(summary.tested) 个节点"]
        if summary.failed > 0 { parts.append("\(summary.failed) 个失败") }
        if let best = summary.best { parts.append("最快 \(best.name) · \(best.latencyMs) ms") }
        return parts.joined(separator: " · ")
    }

    // MARK: M4 — switch airport / node

    private var switchCard: some View {
        VStack(alignment: .leading, spacing: 7) {
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
                menuRow(icon: "tray.full", title: "机场", value: activeProfileName)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(profiles.count <= 1 || engine.configurationBusy)

            if totalMembers > 15 {
                TextField("搜索节点", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(LP.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Menu {
                ForEach(switchable) { group in
                    Menu {
                        ForEach(MenuBarKit.filtered(group, query: query).members) { member in
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
                if switchable.isEmpty { Text("这份配置没有可切换的策略组") }
            } label: {
                menuRow(icon: "point.3.connected.trianglepath.dotted", title: "节点", value: nodeMenuValue)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(switchable.isEmpty || engine.configurationBusy)
        }
        .padding(10)
        .background(LP.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var activeProfileName: String {
        profiles.first { $0.id == snapshot?.activeProfile }?.name ?? engine.profile.name
    }

    private var nodeMenuValue: String {
        guard engine.state == .running else { return "未运行" }
        return snapshot?.current ?? "—"
    }

    private func menuRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 9)).frame(width: 13)
                .foregroundStyle(LP.textTertiary)
            Text(title).font(.system(size: 11.5))
            Spacer(minLength: 6)
            Text(value).font(.system(size: 11))
                .foregroundStyle(LP.textSecondary)
                .lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                .foregroundStyle(LP.textTertiary)
        }
        .foregroundStyle(LP.text)
        .contentShape(Rectangle())
    }

    private func nodeLabel(_ node: MenuBarNode, selected: Bool) -> String {
        let mark = selected ? "✓ " : ""
        let latency = node.dialable ? " · \(MenuBarKit.latencyText(node.latencyMs, failed: node.failed))" : ""
        return mark + node.name + latency
    }

    // MARK: Toggles / metrics / address

    private var toggles: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text("系统代理").font(.system(size: 12))
                Spacer()
                LPSwitch(isOn: Binding(
                    get: { engine.systemProxyActive },
                    set: { on in Task { await engine.toggleSystemProxy(on) } }
                ), width: 30)
            }
            HStack(spacing: 8) {
                Text("实时浮窗").font(.system(size: 12))
                Spacer()
                LPSwitch(isOn: Binding(
                    get: { floating.isVisible },
                    set: { $0 ? floating.show() : floating.hide() }
                ), width: 30)
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            metric("连接", "\(engine.activeConnections)")
            metric("请求", "\(engine.stats.requests)")
            metric("拦截", "\(engine.stats.blocked)")
            Spacer()
            metric("流量", Fmt.bytes(engine.stats.bytesIn + engine.stats.bytesOut))
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(LPFont.num(11, weight: .semibold)).foregroundStyle(LP.text)
            Text(label).font(.system(size: 9)).foregroundStyle(LP.textTertiary)
        }
    }

    private var address: some View {
        Button {
            LPClipboard.copy("127.0.0.1:\(engine.profile.general.mixedPort)")
            app.showToast("已复制代理地址")
        } label: {
            HStack(spacing: 5) {
                Text("127.0.0.1:\(engine.profile.general.mixedPort)")
                    .font(LPFont.mono(10, weight: .medium))
                Image(systemName: "doc.on.doc").font(.system(size: 9))
            }
            .foregroundStyle(LP.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help("复制代理地址")
    }

    // MARK: Issues — why a start did not work

    @ViewBuilder
    private var issues: some View {
        if let error = actionError ?? engineFailure {
            issueRow(icon: "exclamationmark.triangle.fill", text: error, tint: LP.danger)
        }
        if let conflicts = report?.conflicts, !conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(conflicts, id: \.port) { conflict in
                    Text("· " + conflict.summary)
                }
            }
            .font(.system(size: 9.5))
            .foregroundStyle(LP.danger)
            .lineLimit(3)
        }
        // Only worth saying in Mihomo mode: that is the mode where a second kernel
        // fights ours for the same traffic.
        if engine.executionKernel == .mihomo, let note = report?.foreignKernelNote {
            issueRow(icon: "cpu", text: note, tint: LP.amber)
        }
        if report?.auditFailed == true {
            issueRow(icon: "questionmark.circle", text: "端口检查不可用（lsof 未返回结果），占用情况未知", tint: LP.textTertiary)
        }
    }

    private func issueRow(icon: String, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: icon).font(.system(size: 9)).padding(.top, 1)
            Text(text).lineLimit(3).textSelection(.enabled)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(tint)
    }

    // MARK: Navigation / footer

    private var navigation: some View {
        VStack(spacing: 1) {
            ForEach([AppModel.Section.dashboard, .rules, .capture, .settings]) { section in
                Button {
                    app.go(to: section)
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: section.icon).font(.system(size: 9)).frame(width: 14)
                        Text(section.title).font(.system(size: 12))
                        Spacer()
                    }
                    .foregroundStyle(LP.textSecondary)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                app.showPalette = true
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack(spacing: 5) {
                    Text("命令面板").font(.system(size: 12))
                    Spacer()
                    LPKeyCap(keys: "⌘K")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button("打开主窗口") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))

            Button("退出 Leapin") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(LP.textSecondary)
        }
    }

    // MARK: Actions

    private func refresh() async {
        actionError = nil
        snapshot = await engine.menuBarSnapshot()
        report = await engine.portReport()
        if let current = snapshot?.current, let latency = snapshot?.currentLatencyMs,
           quick?.name != current || quick?.latencyMs == nil {
            quick = MenuBarTestOutcome(name: current, latencyMs: latency)
        }
        status.current = quick
        status.best = summary?.best
    }

    private func quickTest() {
        guard !testingOne else { return }
        testingOne = true
        Task {
            let outcome = await engine.menuBarQuickTest()
            quick = outcome
            status.current = outcome
            testingOne = false
            await refresh()
        }
    }

    private func testAll() {
        guard !testingAll else { return }
        testingAll = true
        progress = (0, 0)
        status.pending = 1
        Task {
            let outcome = await engine.menuBarTestAll { done, total in
                progress = (done, total)
                status.pending = max(1, total - done)
            }
            summary = outcome
            status.best = outcome.best
            status.pending = 0
            testingAll = false
            await refresh()
        }
    }

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
            quick = nil
            summary = nil
            status.reset()
            await refresh()
        }
    }
}
