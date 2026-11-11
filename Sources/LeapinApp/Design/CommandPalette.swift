import SwiftUI
import LeapinRuntime

/// One executable entry in the command palette.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let group: String
    let shortcut: String?
    let run: () -> Void
}

/// ⌘K palette: search every page and every frequent action without hunting the sidebar.
@MainActor
struct CommandPalette: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var engine = LeapinEngine.shared

    @State private var query = ""
    @State private var index = 0
    @FocusState private var fieldFocused: Bool

    private var commands: [PaletteCommand] {
        var items: [PaletteCommand] = []
        let device = engine.profile.general.mixedPort
        let running = engine.state == .running

        items.append(PaletteCommand(id: "company", title: "公司内网与团队资源", subtitle: "任意客户端、系统 VPN、浏览器登录与专用代理", icon: "building.2", group: "需求", shortcut: nil, run: { app.showCompany = true }))
        items.append(PaletteCommand(id: "share-service", title: "限时分享本地服务", subtitle: "预览端口、访问范围与有效期 · cloudflared", icon: "link", group: "需求", shortcut: nil, run: { app.networkToolPage = 0; app.showNetworkTools = true }))
        items.append(PaletteCommand(id: "debug-channel", title: "建立 HTTPS 调试通道", subtitle: "指定网站 · mitmproxy 解密 · Mihomo 出站", icon: "curlybraces.square", group: "需求", shortcut: nil, run: { app.networkToolPage = 1; app.showNetworkTools = true }))
        items.append(PaletteCommand(id: "tool-credits", title: "工具与致谢", subtitle: "开源作者、依赖版本、原项目、文档与许可证", icon: "heart", group: "配置", shortcut: nil, run: { app.networkToolPage = 2; app.showNetworkTools = true }))
        items.append(PaletteCommand(
            id: "task-connect", title: "连接网络",
            subtitle: "自动启动服务并接入系统代理", icon: "network", group: "需求", shortcut: nil,
            run: { app.openTask("连接网络") }))
        items.append(PaletteCommand(
            id: "home", title: "回家 · Tailscale",
            subtitle: "检查并打开绑定的家庭资源", icon: "house", group: "需求", shortcut: nil,
            run: { app.openTask("回家") }))
        items.append(PaletteCommand(
            id: "bookmarks", title: "管理与导入浏览器书签",
            subtitle: "HTML / Chromium JSON · 本地预览、去重与撤销", icon: "bookmark", group: "配置", shortcut: nil,
            run: { app.showBookmarks = true }))
        items.append(PaletteCommand(
            id: "local-diagnostics", title: "检查本地代理与日志",
            subtitle: "读取状态、归类日志，不发起外部网站请求", icon: "stethoscope", group: "需求", shortcut: nil,
            run: { app.assistant.inspectLocal(); app.go(to: .diagnostics) }))
        items.append(PaletteCommand(
            id: "task-nas", title: "访问局域网共享文件",
            subtitle: "发现共享设备并连接", icon: "externaldrive", group: "需求", shortcut: nil,
            run: { app.openTask("访问家里的文件") }))
        items.append(PaletteCommand(
            id: "task-learn", title: "为 App 安排网络",
            subtitle: "从应用名称或截图开始", icon: "app.connected.to.app.below.fill", group: "需求", shortcut: nil,
            run: { app.openTask("为 App 安排网络") }))
        items.append(PaletteCommand(
            id: "task-privacy", title: "减少广告和跟踪",
            subtitle: "过滤列表与网站例外", icon: "hand.raised", group: "需求", shortcut: nil,
            run: { app.openTask("减少广告和跟踪") }))

        items.append(PaletteCommand(
            id: "toggle", title: running ? "停止代理" : "启动代理",
            subtitle: running ? "释放端口并断开当前连接" : "在 :\(device) 启动混合代理",
            icon: running ? "stop.circle" : "play.circle", group: "操作",
            shortcut: "⌘⇧P", run: { app.toggle() }))

        items.append(PaletteCommand(
            id: "system-proxy", title: engine.systemProxyActive ? "关闭系统代理" : "开启系统代理",
            subtitle: "写入网络服务的 HTTP/HTTPS/SOCKS 设置，可随时回滚",
            icon: "network", group: "操作", shortcut: "⌘⇧Y",
            run: { engine.toggleSystemProxy(!engine.systemProxyActive) }))

        items.append(PaletteCommand(
            id: "adblock", title: engine.adblockActive ? "关闭去广告" : "开启去广告",
            subtitle: "\(engine.adblockRuleCount) 条过滤规则",
            icon: "hand.raised", group: "操作", shortcut: nil,
            run: {
                let target = !engine.adblockActive
                engine.setAdBlockEnabled(target)
                app.showToast(target ? "去广告已开启" : "去广告已关闭", kind: .info)
            }))

        if engine.executionKernel == .native {
        items.append(PaletteCommand(
            id: "mitm", title: engine.mitmActive ? "关闭 HTTPS 解密" : "开启 HTTPS 解密",
            subtitle: "需要安装并信任 Leapin Root CA",
            icon: "lock.open", group: "操作", shortcut: nil,
            run: {
                let target = !engine.mitmActive
                engine.setMITMEnabled(target)
                app.showToast(target ? "HTTPS 解密已开启" : "HTTPS 解密已关闭", kind: .info)
            }))

        }

        items.append(PaletteCommand(
            id: "reload", title: "重新载入配置",
            subtitle: engine.profile.name, icon: "arrow.clockwise", group: "操作",
            shortcut: "⌘⇧R", run: { Task { await engine.reloadProfile() } }))

        items.append(PaletteCommand(
            id: "import-link", title: "从剪贴板导入订阅链接",
            subtitle: "读取剪贴板里的 http(s) 订阅并下载", icon: "link",
            group: "配置", shortcut: nil, run: { app.importFromClipboardLink() }))

        items.append(PaletteCommand(
            id: "import", title: "导入配置…",
            subtitle: "Clash YAML / Surge conf / Leapin JSON", icon: "square.and.arrow.down",
            group: "配置", shortcut: "⌘O", run: { app.showImporter = true }))

        for format in ProfileFormat.allCases {
            items.append(PaletteCommand(
                id: "export-\(format.cliName)", title: "导出 \(exportLabel(format))",
                subtitle: "写入到本地文件（\(format.fileExtension)）", icon: "square.and.arrow.up",
                group: "配置", shortcut: nil, run: { app.exportProfile(format: format) }))
        }

        items.append(PaletteCommand(
            id: "ca", title: "安装 CA 证书",
            subtitle: "打开证书文件并在钥匙串中信任", icon: "checkmark.seal",
            group: "配置", shortcut: nil, run: { app.installCA() }))

        items.append(PaletteCommand(
            id: "copy-endpoint", title: "复制代理地址",
            subtitle: "127.0.0.1:\(device)", icon: "doc.on.doc",
            group: "配置", shortcut: nil,
            run: {
                LPClipboard.copy("127.0.0.1:\(device)")
                app.showToast("已复制 127.0.0.1:\(device)")
            }))

        let shortcuts = ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘7", "⌘8", "⌘9", "⌘0"]
        for (i, section) in AppModel.Section.allCases.enumerated() {
            items.append(PaletteCommand(
                id: "go-\(section.rawValue)", title: "前往\(section.title)",
                subtitle: section.subtitle, icon: section.icon, group: "前往",
                shortcut: i < shortcuts.count ? shortcuts[i] : nil,
                run: { app.go(to: section) }))
        }
        return items
    }

    private var results: [PaletteCommand] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return commands }
        let matches = commands.filter { command in
            let haystack = (command.title + command.subtitle + command.group).lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
        switch NetworkTask.parse(query) {
        case .inspect, .direct:
            return [PaletteCommand(id: "task-query", title: "为这个网站查看计划",
                subtitle: query, icon: "list.bullet.clipboard", group: "需求", shortcut: nil,
                run: { app.openTask(query) })] + matches
        default: return matches
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "command")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LP.accent)
                    TextField("输入网站、需求或工具名称…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($fieldFocused)
                        .onSubmit { runSelected() }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                    LPKeyCap(keys: "esc")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Rectangle().fill(LP.stroke).frame(height: 1)

                if results.isEmpty {
                    Text("暂不支持这个需求。可输入网站地址，或搜索「配置」「规则」等工具。")
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 26)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { offset, command in
                                    row(command, selected: offset == index)
                                        .id(command.id)
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 340)
                        .onChange(of: index) { _, newValue in
                            guard results.indices.contains(newValue) else { return }
                            LPMotion.run(LPMotion.press) { proxy.scrollTo(results[newValue].id, anchor: .center) }
                        }
                    }
                }

                Rectangle().fill(LP.stroke).frame(height: 1)
                HStack(spacing: 12) {
                    hint("↑↓", "选择")
                    hint("↩", "执行")
                    hint("esc", "关闭")
                    Spacer()
                    Text("\(results.count) 项")
                        .font(LPFont.num(9.5))
                        .foregroundStyle(LP.textTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(width: 520)
            .lpGlass(radius: 22,
                     fallbackFill: LP.panelSolid,
                     fallbackMaterial: .regularMaterial,
                     shadow: 0.30)
            .padding(.top, 90)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            index = 0
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: query) { _, _ in index = 0 }
    }

    private func row(_ command: PaletteCommand, selected: Bool) -> some View {
        Button {
            command.run()
            close()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: command.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(selected ? LP.accent : LP.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(LP.text)
                    Text(command.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(LP.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(command.group)
                    .font(.system(size: 9))
                    .foregroundStyle(LP.textTertiary)
                if let shortcut = command.shortcut {
                    LPKeyCap(keys: shortcut)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? LP.accentSoft : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(command.title)，\(command.subtitle)")
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            LPKeyCap(keys: key)
            Text(label).font(.system(size: 9)).foregroundStyle(LP.textTertiary)
        }
    }

    /// Human label for an export target ("Clash YAML" reads better than "clash").
    private func exportLabel(_ format: ProfileFormat) -> String {
        switch format {
        case .clash: return "Clash 配置"
        case .surge: return "Surge 配置"
        case .json: return "Leapin JSON"
        case .hosts: return "Hosts 拦截表"
        case .abp: return "ABP 过滤列表"
        case .ruleSet: return "Clash rule-set"
        }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        index = min(max(index + delta, 0), results.count - 1)
    }

    private func runSelected() {
        guard results.indices.contains(index) else { return }
        results[index].run()
        close()
    }

    private func close() {
        app.showPalette = false
        fieldFocused = false
    }
}
