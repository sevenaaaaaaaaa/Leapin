import SwiftUI
import AppKit
import TouchFlowCore
import TouchFlowRuntime
import TouchFlowPolicy
import TouchFlowNet
import TouchFlowIntegrations

@MainActor
struct CaptureView: View {
    @ObservedObject private var engine = TouchFlowEngine.shared
    @EnvironmentObject private var app: AppModel
    @State private var search = ""
    @State private var selected: UUID?
    @State private var showMITMWarning = false
    @State private var showClearConfirm = false
    @State private var paused = false
    @State private var frozen: [CapturedRequest] = []
    @State private var statusFilter: StatusFilter = .all
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum StatusFilter: String, CaseIterable, Identifiable {
        case all, success, redirect, clientError, blocked
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .success: return "2xx"
            case .redirect: return "3xx"
            case .clientError: return "4xx+"
            case .blocked: return "已拦截"
            }
        }
        func matches(_ request: CapturedRequest) -> Bool {
            switch self {
            case .all: return true
            case .blocked: return request.blocked
            case .success: return (request.statusCode ?? 0) >= 200 && (request.statusCode ?? 0) < 300
            case .redirect: return (request.statusCode ?? 0) >= 300 && (request.statusCode ?? 0) < 400
            case .clientError: return (request.statusCode ?? 0) >= 400
            }
        }
    }

    @State private var freshID: UUID?

    private var source: [CapturedRequest] { paused ? frozen : engine.captures }

    private var filtered: [CapturedRequest] {
        let q = search.lowercased()
        return source.filter { request in
            guard statusFilter.matches(request) else { return false }
            guard !q.isEmpty else { return true }
            return request.url.lowercased().contains(q) || request.host.lowercased().contains(q)
        }
    }

    private var current: CapturedRequest? {
        source.first { $0.id == selected }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            filterRow
            Rectangle().fill(TF.stroke).frame(height: 1)
            // 窄窗口或无选中项时只留列表：空详情栏占掉半屏，是首屏最贵的空白。
            GeometryReader { geo in
                Group {
                    if current == nil {
                        list
                    } else if geo.size.width < 820 {
                        // 窄窗不再永久分栏（会留半屏空详情），改为选中后从右侧推出的检视层。
                        ZStack(alignment: .trailing) {
                            list
                            VStack(spacing: 0) {
                                HStack(spacing: 8) {
                                    TFEyebrow(text: "请求详情 / REQUEST")
                                    Spacer(minLength: 6)
                                    Text("esc")
                                        .font(TFFont.mono(10))
                                        .foregroundStyle(TF.textTertiary)
                                    Button {
                                        selected = nil
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(TF.textSecondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("关闭详情")
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                TFDivider()
                                detail
                            }
                            .frame(width: max(330, geo.size.width * 0.56))
                            .tfGlass(radius: 14,
                                     fallbackFill: TF.panel,
                                     fallbackMaterial: .regularMaterial,
                                     shadow: 0.18)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                        .tfAnimation(TFMotion.standard, value: current?.id)
                    } else {
                        HSplitView {
                            list
                                .frame(minWidth: 336)
                            detail
                                .frame(minWidth: 336)
                        }
                    }
                }
            }
            .tfGlass(radius: TFGlass.panelRadius,
                     fallbackFill: TF.panel,
                     shadow: 0.06)
            .padding(.horizontal, 32)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .onExitCommand { selected = nil }
        .navigationTitle("抓包")
        .alert("HTTPS 解密需要信任证书", isPresented: $showMITMWarning) {
            Button("去安装 CA") { app.installCA() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("开启后 TouchFlow 会用本地 CA 为 HTTPS 站点签发证书。请先把 touchflow-ca.pem 加入系统钥匙串并设为“始终信任”，否则客户端会报证书错误。")
        }
        .tfConfirm("清空所有记录？",
                   message: "会同时清空最近连接与抓包记录，已导出的 HAR 不受影响。",
                   isPresented: $showClearConfirm,
                   confirmTitle: "清空") {
            engine.clearFlows()
            selected = nil
            frozen = []
            paused = false
            app.showToast("已清空记录", kind: .info)
        }
        .onChange(of: app.searchFocusRequest) { _, _ in
            searchFocused = true
        }
        .onChange(of: filtered.count) { _, _ in
            if let selected, !source.contains(where: { $0.id == selected }) { self.selected = nil }
        }
        .onChange(of: filtered.first?.id) { _, id in
            guard !paused, let id else { return }
            freshID = id
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if freshID == id { TFMotion.run(TFMotion.emphasized) { freshID = nil } }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TFSearchField(text: $search, placeholder: "过滤 URL / 主机", width: 210, focus: $searchFocused)

            Spacer()

            Button {
                if paused {
                    paused = false
                    frozen = []
                } else {
                    frozen = engine.captures
                    paused = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 9, weight: .bold))
                    Text(paused ? "继续" : "暂停").font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(TFGhostButtonStyle())
            .help(paused ? "恢复实时刷新" : "冻结当前列表，便于阅读")
            .disabled(engine.captures.isEmpty && !paused)

            Rectangle().fill(TF.strokeStrong.opacity(0.6)).frame(width: 1, height: 16)

            HStack(spacing: 7) {
                Text("HTTPS 解密")
                    .font(.system(size: 12))
                    .foregroundStyle(TF.textSecondary)
                TFSwitch(isOn: Binding(
                    get: { engine.profile.general.mitmEnabled },
                    set: { enabled in
                        if enabled { showMITMWarning = true }
                        engine.setMITMEnabled(enabled)
                    }
                ), width: 30)
            }

            Rectangle().fill(TF.strokeStrong.opacity(0.6)).frame(width: 1, height: 16)

            Button { exportHAR() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 9, weight: .bold))
                    Text("导出 HAR").font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(TFGhostButtonStyle())
            .disabled(engine.captures.isEmpty)

            Button { showClearConfirm = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash").font(.system(size: 9, weight: .bold))
                    Text("清空").font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(TFGhostButtonStyle())
            .disabled(engine.captures.isEmpty && engine.flows.isEmpty)
        }
        .padding(.horizontal, 32).padding(.vertical, 13)
    }

    private var filterRow: some View {
        HStack(spacing: 5) {
            ForEach(StatusFilter.allCases) { option in
                TFChip(title: option.title, selected: statusFilter == option) {
                    TFMotion.run(TFMotion.press) { statusFilter = option }
                }
            }
            Spacer()
            Text(paused
                 ? "已暂停 · \(filtered.count) / \(source.count) 条"
                 : (search.isEmpty && statusFilter == .all
                    ? "\(filtered.count) 条"
                    : "\(filtered.count) / \(source.count)"))
                .font(TFFont.num(10, weight: .medium))
                .foregroundStyle(paused ? TF.amber : TF.textTertiary)
                .fixedSize()
            if !search.isEmpty || statusFilter != .all {
                Button("清除筛选") {
                    search = ""
                    statusFilter = .all
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(TF.accent)
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 11)
    }

    /// 空态不是一块居中留白，而是一张「还没填的账」：列头在，行位在，动作在底部。
    private var emptyList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Text("方法").frame(width: 46, alignment: .leading)
                Text("主机 / 路径")
                Spacer(minLength: 8)
                Text("状态").frame(width: 34, alignment: .trailing)
                Text("耗时").frame(width: 52, alignment: .trailing)
            }
            .font(TFFont.mono(10, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(TF.textTertiary)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)

            TFDivider()

            // 空态不用骨架屏：永久骨架会被读成「正在加载」，与「没有数据」是两件事。
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(engine.profile.general.captureEnabled ? "暂无 HTTP 请求" : "抓包已在设置中关闭")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TF.text)
                    Text(engine.profile.general.captureEnabled
                         ? "把应用流量指向 127.0.0.1:\(engine.profile.general.mixedPort)，明文请求会逐条落在这里；HTTPS 需开启解密。"
                         : "到设置页打开「抓包」后再回来。")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(engine.profile.general.captureEnabled
                       ? (app.isRunning ? "复制代理地址" : "启动代理并抓包")
                       : "打开设置") {
                    if !engine.profile.general.captureEnabled {
                        app.go(to: .settings)
                    } else if app.isRunning {
                        TFClipboard.copy("http://127.0.0.1:\(engine.profile.general.mixedPort)")
                        app.showToast("已复制代理地址", kind: .info)
                    } else {
                        app.toggle()
                    }
                }
                .buttonStyle(TFPrimaryButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 15)

            // 空白账页：只有横线，没有占位胶囊——读作「还没写」，不是「正在加载」。
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { _ in
                    Rectangle()
                        .fill(TF.stroke)
                        .frame(height: 1)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 35)
                }
            }
            .accessibilityHidden(true)

            Spacer(minLength: 0)
        }
    }

    private var list: some View {
        Group {
            if filtered.isEmpty {
                emptyList
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 9) {
                        Text("方法").frame(width: 46, alignment: .leading)
                        Text("主机 / 路径")
                        Spacer(minLength: 8)
                        Text("状态").frame(width: 34, alignment: .trailing)
                        Text("耗时").frame(width: 52, alignment: .trailing)
                    }
                    .font(TFFont.mono(10, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(TF.textTertiary)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 7)
                    Rectangle().fill(TF.stroke.opacity(0.7)).frame(height: 0.5)
                    ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filtered) { request in
                            TFRow(selected: selected == request.id,
                                  accessibilityText: "\(request.method) \(request.host)\(path(request.url))") {
                                selected = request.id
                                listFocused = true
                            } content: {
                                captureRow(request)
                            }
                            .contextMenu {
                                Button("复制 URL") {
                                    TFClipboard.copy(request.url)
                                    app.showToast("已复制 URL", kind: .info)
                                }
                                Button("复制为 cURL") {
                                    TFClipboard.copy(curl(for: request))
                                    app.showToast("已复制 cURL 命令", kind: .info)
                                }
                            }
                        }
                    }
                    .padding(8)
                    }
                    .scrollIndicators(.visible)
                    .focusable()
                    .focused($listFocused)
                    .onMoveCommand { direction in moveSelection(direction) }
                }
            }
        }
    }

    private func captureRow(_ request: CapturedRequest) -> some View {
        HStack(spacing: 9) {
            Rectangle()
                .fill(request.id == freshID ? TF.accent : Color.clear)
                .frame(width: 2, height: 15)
                .tfAnimation(TFMotion.emphasized, value: freshID)
            Text(request.method)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .frame(width: 32)
                .padding(.vertical, 3)
                .background(methodColor(request.method).opacity(0.10), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .foregroundStyle(methodColor(request.method))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if request.blocked {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(TF.danger)
                    }
                    Text(request.host)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TF.text)
                        .lineLimit(1)
                }
                Text(path(request.url))
                    .font(TFFont.mono(10))
                    .foregroundStyle(TF.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let code = request.statusCode {
                Text(String(code))
                    .font(TFFont.num(10.5, weight: .semibold))
                    .foregroundStyle(code < 400 ? TF.success : TF.danger)
                    .frame(width: 34, alignment: .trailing)
            } else {
                Text("—")
                    .font(TFFont.num(10.5))
                    .foregroundStyle(TF.textTertiary)
                    .frame(width: 34, alignment: .trailing)
            }
            Text(Fmt.duration(request.durationMs))
                .font(TFFont.num(10))
                .foregroundStyle(TF.textTertiary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !filtered.isEmpty else { return }
        let currentIndex = filtered.firstIndex(where: { $0.id == selected })
        switch direction {
        case .up:
            selected = filtered[max(0, (currentIndex ?? 0) - 1)].id
        case .down:
            selected = filtered[min(filtered.count - 1, (currentIndex ?? -1) + 1)].id
        default:
            break
        }
    }

    private var detail: some View {
        Group {
            if let req = current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Badge(text: req.method, color: methodColor(req.method))
                            Text(req.url).font(TFFont.mono(12)).textSelection(.enabled).lineLimit(2)
                            Spacer(minLength: 6)
                            Menu {
                                Button("复制 URL") {
                                    TFClipboard.copy(req.url)
                                    app.showToast("已复制 URL", kind: .info)
                                }
                                Button("复制为 cURL") {
                                    TFClipboard.copy(curl(for: req))
                                    app.showToast("已复制 cURL 命令", kind: .info)
                                }
                                if !req.requestHeaders.isEmpty {
                                    Button("复制请求头") {
                                        let text = req.requestHeaders.sorted { $0.key < $1.key }
                                            .map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                                        TFClipboard.copy(text)
                                        app.showToast("已复制请求头", kind: .info)
                                    }
                                }
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .frame(width: 22)
                            .help("复制请求")
                        }
                        HStack(spacing: 10) {
                            if let code = req.statusCode {
                                Text(String(code))
                                    .font(TFFont.num(11, weight: .semibold))
                                    .foregroundStyle(code < 400 ? TF.text : TF.danger)
                            }
                            if let mime = req.mimeType {
                                Text(mime)
                                    .font(TFFont.mono(9.5))
                                    .foregroundStyle(TF.textTertiary)
                                    .lineLimit(1)
                            }
                            Text(Fmt.clock(req.timestamp))
                                .font(TFFont.mono(9.5))
                                .foregroundStyle(TF.textTertiary)
                            Text(Fmt.duration(req.durationMs))
                                .font(TFFont.num(9.5))
                                .foregroundStyle(TF.textTertiary)
                            Spacer(minLength: 6)
                            if req.blocked { Badge(text: "已拦截", color: TF.danger) }
                        }
                        HStack(spacing: 10) {
                            if let app = req.sourceApp, !app.isEmpty {
                                Label(app, systemImage: "app.dashed")
                                    .font(TFFont.mono(10))
                                    .foregroundStyle(TF.textSecondary)
                                    .lineLimit(1)
                            }
                            if let ip = req.sourceIP, !ip.isEmpty {
                                Label(ip, systemImage: "point.3.connected.trianglepath.dotted")
                                    .font(TFFont.mono(10))
                                    .foregroundStyle(TF.textTertiary)
                            }
                            Spacer(minLength: 4)
                        }
                        if let chain = req.chain {
                            RuleChainCard(chain: chain)
                        }
                        headersCard("请求头", req.requestHeaders)
                        if let body = req.requestBody, !body.isEmpty {
                            bodyCard("请求体", body)
                        }
                        headersCard("响应头", req.responseHeaders)
                        if let body = req.responseBody, !body.isEmpty {
                            bodyCard("响应体", body)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                TFEmptyState(icon: "sidebar.right",
                             title: "选择左侧请求查看详情",
                             message: "会显示经过脱敏的请求头、请求体与响应内容。")
            }
        }
    }

    private func headersCard(_ title: String, _ headers: [String: String]) -> some View {
        Card(title: title, subtitle: "\(headers.count) 项", icon: "list.bullet") {
            if headers.isEmpty {
                Text("无").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(alignment: .top, spacing: 8) {
                            Text(key).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .frame(width: 150, alignment: .leading)
                            Text(Redactor.redact(value)).font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func bodyCard(_ title: String, _ data: Data) -> some View {
        Card(title: title, subtitle: Fmt.bytes(data.count), icon: "doc.plaintext") {
            ScrollView(.horizontal) {
                Text(preview(data)).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func preview(_ data: Data) -> String {
        let text = String(data: data.prefix(4000), encoding: .utf8) ?? "<二进制 \(data.count) 字节>"
        return Redactor.redact(text)
    }

    private func path(_ url: String) -> String {
        URL(string: url)?.path ?? url
    }

    private func curl(for request: CapturedRequest) -> String {
        var parts = ["curl -X \(request.method)"]
        parts.append("'\(request.url)'")
        for (key, value) in request.requestHeaders.sorted(by: { $0.key < $1.key }) {
            parts.append("-H '\(key): \(value)'")
        }
        if let body = request.requestBody, let text = String(data: body, encoding: .utf8), !text.isEmpty {
            parts.append("--data-raw '\(text.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
        return parts.joined(separator: " \\\n  ")
    }

    private func methodColor(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": return .blue
        case "POST": return .green
        case "PUT", "PATCH": return .orange
        case "DELETE": return .red
        default: return .secondary
        }
    }

    private func exportHAR() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "touchflow.har"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try engine.exportHAR()
            try data.write(to: url)
            let count = engine.captures.count
            app.showToast("已导出 \(count) 条请求（敏感头已脱敏）", kind: .success, actionTitle: "在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            app.showToast("导出失败：\(error.localizedDescription)", kind: .error)
        }
    }
}
