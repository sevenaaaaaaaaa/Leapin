import SwiftUI
import AppKit
import LeapinCore
import LeapinControl
import LeapinRuntime
import LeapinPolicy
import LeapinNet
import LeapinIntegrations

@MainActor
struct ProfilesView: View {
    @ObservedObject private var engine = LeapinEngine.shared
    @EnvironmentObject private var app: AppModel
    @State private var metas: [ProfileMeta] = []
    @State private var pendingDelete: ProfileMeta?
    @State private var search = ""
    @State private var activating: UUID?
    @FocusState private var searchFocused: Bool
    @State private var nodes: [ControlNode] = []
    @State private var testingAll = false
    @State private var testingNodes: Set<String> = []
    @State private var autoTestTriggered = false
    @State private var speedResults: [String: ControlNodeSpeedResult] = [:]
    @State private var speedTesting: Set<String> = []

    /// 作为「走哪」的 tab 出现时传 `false`：那一屏的页头与 tab 标题已经写明你在哪，
    /// 这里的大标题（「当前配置」+ 配置名）就是第三遍重复。
    ///
    /// 只影响标题块：导入 / 粘贴订阅 / 导出 / 打开目录等动作与全部业务逻辑照旧。
    var showsPageHeader: Bool = true

    init(showsPageHeader: Bool = true) {
        self.showsPageHeader = showsPageHeader
    }

    private var currentMeta: ProfileMeta? {
        metas.first { $0.id == engine.profile.id }
    }

    /// Latency tests work in both modes: native dials the node, Mihomo asks the
    /// kernel to (only the kernel can speak clash protocols).
    private var canTestLatency: Bool {
        engine.executionKernel == .native || engine.managedKernel.running
    }

    private func activate(_ meta: ProfileMeta) {
        activating = meta.id
        Task {
            await engine.activate(meta.id)
            activating = nil
            refresh()
            if engine.profile.id == meta.id, engine.lastError == nil {
                app.showToast("已切换到 \(meta.name)", kind: .success)
            } else {
                app.showToast("切换失败：\(engine.lastError ?? "配置无法载入")", kind: .error)
            }
        }
    }

    private var filtered: [ProfileMeta] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return metas }
        return metas.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                heroPanel
                if engine.executionKernel == .mihomo { ManagedKernelPanel() }
                nodesPanel
                listPanel
                importSourcesPanel
            }
            .pagePadding()
        }
        .navigationTitle("配置")
        .onAppear(perform: refresh)
        .task { await refreshNodesAndMaybeAutoTest() }
        .onChange(of: engine.profile.id) { _, _ in
            refresh()
            autoTestTriggered = false
            Task { await refreshNodesAndMaybeAutoTest() }
        }
        .onChange(of: app.searchFocusRequest) { _, _ in searchFocused = true }
        .lpConfirm("删除配置？",
                   message: "将同时删除该配置的本地 JSON 文件，不可恢复。",
                   isPresented: Binding(get: { pendingDelete != nil },
                                        set: { if !$0 { pendingDelete = nil } }),
                   confirmTitle: "删除") {
            if let meta = pendingDelete {
                engine.store.delete(id: meta.id)
                refresh()
                app.showToast("已删除 \(meta.name)", kind: .info)
            }
            pendingDelete = nil
        }
    }

    // MARK: Hero

    private var heroPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                // 大标题只在这一页独立成页时出现；作为 tab 时它被 tab 标题取代。
                if showsPageHeader {
                    heroTitle
                }

                if showsPageHeader {
                    Spacer(minLength: 12)
                }

                heroActions

                if !showsPageHeader {
                    Spacer(minLength: 0)
                }
            }

            Text("先检查格式与执行内核，确认后再启用。Mihomo 方案保留原始 Clash 文本；转换格式时需检查目标能表达的范围。")
                .font(.system(size: 12))
                .foregroundStyle(LP.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lpPanel(padding: 0)
        .lpAppear(0)
    }

    /// 页面大标题块：「当前配置 / Active profile」+ 配置名 + 规则数 / 更新日 / 已启用。
    private var heroTitle: some View {
        VStack(alignment: .leading, spacing: 7) {
            LPEyebrow("当前配置 / Active profile")

            Text(engine.profile.name)
                .font(LPFont.display(20, weight: .semibold))
                .foregroundStyle(LP.text)
                .lineLimit(1)

            HStack(spacing: 7) {
                Text("\(engine.ruleCount) 条规则")
                    .font(LPFont.mono(12))
                    .foregroundStyle(LP.textSecondary)
                Text("·")
                    .font(LPFont.mono(12))
                    .foregroundStyle(LP.textTertiary)
                Text(currentMeta.map { Fmt.day($0.updatedAt) } ?? "本机配置")
                    .font(LPFont.mono(12))
                    .foregroundStyle(LP.textTertiary)
                Circle()
                    .fill(LP.mint)
                    .frame(width: 5, height: 5)
                    .padding(.leading, 4)
                Text("已启用")
                    .font(.system(size: 10))
                    .foregroundStyle(LP.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(engine.ruleCount) 条规则，已启用")
        }
    }

    /// 标题右侧的动作条：导入 / 粘贴订阅 / 导出 / 打开目录。作为 tab 时整条仍在，
    /// 只是不再和大标题并排（能力不能因为换了个容器就消失）。
    private var heroActions: some View {
        HStack(spacing: 8) {
            Button {
                app.beginImport()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 9, weight: .bold))
                    Text("导入配置")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .buttonStyle(LPPrimaryButtonStyle())
            .accessibilityLabel("导入配置")

            Button {
                app.importFromClipboardLink()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .bold))
                    Text("粘贴订阅")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .buttonStyle(LPGhostButtonStyle())
            .help("从剪贴板读取 http(s) 订阅链接并下载导入")
            .accessibilityLabel("粘贴订阅链接")

            Menu {
                Button("Clash YAML") { app.exportProfile(format: .clash) }
                Button("Surge conf") { app.exportProfile(format: .surge) }
                Button("Leapin JSON") { app.exportProfile(format: .json) }
                Divider()
                Button("Hosts 拦截表（REJECT 精确域名）") { app.exportProfile(format: .hosts) }
                Button("ABP / uBlock 过滤列表") { app.exportProfile(format: .abp) }
                Button("Clash rule-set（classical）") { app.exportProfile(format: .ruleSet) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 9, weight: .bold))
                    Text("导出")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundStyle(LP.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .lpGlass(in: Capsule(style: .continuous),
                         fallbackFill: LP.panelSolid,
                         fallbackMaterial: .thinMaterial)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("导出为 Clash / Surge / JSON / Hosts / ABP / rule-set")
            .accessibilityLabel("导出配置")

            Button("打开目录") {
                NSWorkspace.shared.open(engine.store.root)
                app.showToast("已在访达中打开配置目录", kind: .info)
            }
            .buttonStyle(LPGhostButtonStyle())
        }
    }

    // MARK: Profile list

    private var listPanel: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "全部配置",
                          subtitle: "\(filtered.count) / \(metas.count) 个",
                          icon: "list.bullet.rectangle")
                .padding(18)

            LPDivider()

            HStack(spacing: 12) {
                if !metas.isEmpty {
                    LPSearchField(text: $search, placeholder: "搜索配置名", width: 240, focus: $searchFocused)
                }
                Spacer(minLength: 8)
                Text("本机存储 · 先预检再启用")
                    .font(LPFont.mono(10))
                    .tracking(0.8)
                    .foregroundStyle(LP.textTertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            LPDivider()

            if metas.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noResults
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, meta in
                        profileRow(meta)
                        if index < filtered.count - 1 {
                            LPDivider().padding(.leading, 46)
                        }
                    }
                }
            }
        }
        .lpPanel(padding: 0)
        .lpAppear(0.04)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("还没有配置")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LP.textSecondary)
            Text("导入 Clash YAML、Surge conf 或之前导出的 Leapin JSON 即可开始。")
                .font(.system(size: 12))
                .foregroundStyle(LP.textTertiary)
            Button("导入配置") { app.beginImport() }
                .buttonStyle(LPGhostButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private var noResults: some View {
        HStack(spacing: 10) {
            Text("没有匹配的配置。")
                .font(.system(size: 12))
                .foregroundStyle(LP.textTertiary)
            Button("清除搜索") { search = "" }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LP.accent)
                .accessibilityLabel("清除搜索")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private func profileRow(_ meta: ProfileMeta) -> some View {
        let active = meta.id == engine.profile.id
        return HStack(spacing: 12) {
            Image(systemName: active ? "doc.text.fill" : "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(active ? LP.mint : LP.textTertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(meta.name)
                        .font(.system(size: 12, weight: active ? .semibold : .medium))
                        .foregroundStyle(LP.text)
                        .lineLimit(1)
                    if active {
                        Badge(text: "使用中", color: LP.mint)
                    }
                }
                Text("\(meta.ruleCount) 条规则 · \(Fmt.day(meta.updatedAt))")
                    .font(LPFont.mono(10))
                    .foregroundStyle(LP.textTertiary)
            }

            Spacer(minLength: 8)

            if !active {
                Button {
                    activate(meta)
                } label: {
                    if activating == meta.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("启用")
                    }
                }
                .buttonStyle(LPGhostButtonStyle())
                .disabled(activating != nil)
                .accessibilityLabel("启用 \(meta.name)")
            }

            Button(role: .destructive) {
                pendingDelete = meta
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(LP.textTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("删除该配置")
            .accessibilityLabel("删除 \(meta.name)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu {
            Button("启用") { activate(meta) }
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([engine.store.root])
            }
            Divider()
            Button("删除…", role: .destructive) { pendingDelete = meta }
        }
    }


    // MARK: Nodes (M1)

    private var dialableNodes: [ControlNode] { nodes.filter(\.dialable) }

    private var sortedNodes: [ControlNode] {
        nodes.sorted { a, b in
            func rank(_ n: ControlNode) -> Int {
                if n.latencyMs != nil { return 0 }
                if n.checkedAtMs == nil { return 1 }
                return 2
            }
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            if ra == 0 { return (a.latencyMs ?? .max) < (b.latencyMs ?? .max) }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private var aliveCount: Int { dialableNodes.filter { $0.latencyMs != nil }.count }

    private var nodesPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SectionHeader(title: "节点",
                              subtitle: dialableNodes.isEmpty ? "当前配置没有可测速的节点"
                                                             : "\(aliveCount) / \(dialableNodes.count) 在线",
                              icon: "network")
                Spacer(minLength: 8)
                if testingAll {
                    ProgressView().controlSize(.small)
                }
                Button {
                    testAllNodes()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 9, weight: .bold))
                        Text("全部测速")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(LPPrimaryButtonStyle())
                .disabled(testingAll || dialableNodes.isEmpty || !canTestLatency)
                .help(canTestLatency ? "对所有节点做延迟测试（Mihomo 模式由内核拨号）"
                                     : "Mihomo 内核未运行，先启动代理再测速")
                .accessibilityLabel("全部测速")
            }
            .padding(18)

            LPDivider()

            if dialableNodes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("没有节点")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LP.textSecondary)
                    Text("导入订阅或节点 URI 后，这里会列出每个节点的在线状态与延迟。")
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textTertiary)
                    Button("导入配置") { app.beginImport() }
                        .buttonStyle(LPGhostButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sortedNodes.enumerated()), id: \.element.name) { index, node in
                        nodeRow(node)
                        if index < sortedNodes.count - 1 {
                            LPDivider().padding(.leading, 37)
                        }
                    }
                }
            }
        }
        .lpPanel(padding: 0)
        .lpAppear(0.02)
    }

    private func nodeRow(_ node: ControlNode) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(latencyColor(node))
                .frame(width: 7, height: 7)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LP.text)
                        .lineLimit(1)
                    Badge(text: node.type, color: LP.textTertiary)
                    if !node.groups.isEmpty {
                        Text(node.groups.joined(separator: " · "))
                            .font(LPFont.mono(9))
                            .foregroundStyle(LP.textTertiary)
                            .lineLimit(1)
                    }
                }
                if !node.server.isEmpty {
                    Text("\(node.server):\(node.port)")
                        .font(LPFont.mono(10))
                        .foregroundStyle(LP.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                latencyLabel(node)
                if let speed = speedResults[node.name] {
                    if let error = speed.error {
                        Text("测速失败")
                            .font(LPFont.mono(10))
                            .foregroundStyle(LP.danger)
                            .help(error)
                    } else {
                        Text("\(speed.mbps, specifier: "%.2f") Mbps")
                            .font(LPFont.mono(10, weight: .semibold))
                            .foregroundStyle(LP.accent)
                    }
                }
            }

            if node.dialable {
                Button {
                    testOneNode(node.name)
                } label: {
                    if testingNodes.contains(node.name) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(LPGhostButtonStyle())
                .disabled(testingAll || testingNodes.contains(node.name) || !canTestLatency)
                .help("复测 \(node.name) 的延迟")
                .accessibilityLabel("复测 \(node.name)")

                Button {
                    testSpeed(node.name)
                } label: {
                    if speedTesting.contains(node.name) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "bolt")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(LPGhostButtonStyle())
                .disabled(speedTesting.contains(node.name) || engine.executionKernel == .mihomo)
                .help(engine.executionKernel == .mihomo
                      ? "Mihomo 模式的带宽测速需要内核拨号，暂未提供；延迟测速可用"
                      : "带宽测速 \(node.name)（经节点下载 10MB 测试对象）")
                .accessibilityLabel("带宽测速 \(node.name)")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func latencyLabel(_ node: ControlNode) -> some View {
        Group {
            if let ms = node.latencyMs {
                Text("\(ms) ms")
                    .font(LPFont.mono(12, weight: .semibold))
                    .foregroundStyle(latencyColor(node))
            } else if node.checkedAtMs != nil {
                Text("失败")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LP.danger)
                    .help(node.lastError ?? "测试失败")
            } else if !node.dialable {
                Text("原生不可拨")
                    .font(.system(size: 11))
                    .foregroundStyle(LP.textTertiary)
                    .help("原生内核无法拨号该协议；Mihomo 模式下请在内核面板测试")
            } else {
                Text("未测")
                    .font(.system(size: 11))
                    .foregroundStyle(LP.textTertiary)
            }
        }
    }

    private func latencyColor(_ node: ControlNode) -> Color {
        guard let ms = node.latencyMs else { return LP.textTertiary }
        if ms < 200 { return LP.mint }
        if ms <= 800 { return LP.amber }
        return LP.danger
    }

    private func refreshNodesAndMaybeAutoTest() async {
        nodes = await engine.controlNodes()
        // 导入后不做任何操作也应看到链接状态：首次出现且没有任何探测记录时自动测一轮。
        guard !autoTestTriggered, canTestLatency else { return }
        let dialable = dialableNodes
        guard !dialable.isEmpty, dialable.allSatisfy({ $0.checkedAtMs == nil }) else { return }
        autoTestTriggered = true
        testAllNodes()
    }

    private func testAllNodes() {
        guard !testingAll else { return }
        testingAll = true
        Task {
            _ = try? await engine.controlTestNodes(names: [])
            nodes = await engine.controlNodes()
            testingAll = false
        }
    }

    private func testOneNode(_ name: String) {
        testingNodes.insert(name)
        Task {
            _ = try? await engine.controlTestNodes(names: [name])
            nodes = await engine.controlNodes()
            testingNodes.remove(name)
        }
    }

    private func testSpeed(_ name: String) {
        speedTesting.insert(name)
        Task {
            do {
                let result = try await engine.controlSpeedTestNode(name: name, url: nil, sizeMb: nil)
                speedResults[name] = result
                if let error = result.error {
                    app.showToast("\(name) 带宽测速失败：\(error)", kind: .error)
                }
            } catch {
                app.showToast("\(name) 带宽测速失败：\(error.localizedDescription)", kind: .error)
            }
            speedTesting.remove(name)
        }
    }

    // MARK: Import sources

    private var importSourcesPanel: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "导入来源",
                          subtitle: "支持的格式与本机边界",
                          icon: "square.and.arrow.down.on.square")
                .padding(18)

            LPDivider()

            sourceRow("Clash YAML",
                      "proxies · proxy-groups · rules · dns · rule-providers · proxy-providers")
            LPDivider()
            sourceRow("Surge conf",
                      "[General] · [Proxy] · [Proxy Group] · [Rule] · [Host]")
            LPDivider()
            sourceRow("Leapin JSON",
                      "本应用导出的 .json，含出站、策略组、规则、DNS 与去广告列表")
            LPDivider()
            sourceRow("订阅链接",
                      "Clash 订阅、base64 节点列表，或 ss / trojan / vmess / vless / hysteria2 URI；先检查内核兼容性")

            LPDivider()

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10))
                    .foregroundStyle(LP.textTertiary)
                    .padding(.top, 1)
                Text("导入在本机完成，在预览中确认后才启用；订阅只访问你粘贴的 URL，内容不会上传到其他服务器。")
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .lpPanel(padding: 0)
        .lpAppear(0.08)
    }

    private func sourceRow(_ name: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(name)
                .font(LPFont.mono(12))
                .foregroundStyle(LP.textSecondary)
                .frame(width: 130, alignment: .leading)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(LP.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func refresh() {
        metas = engine.profiles
    }
}
