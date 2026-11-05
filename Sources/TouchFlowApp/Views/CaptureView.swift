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
            HSplitView {
                list
                    .frame(minWidth: 380)
                    .background(TF.panel, in: RoundedRectangle(cornerRadius: TF.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: TF.radius, style: .continuous).strokeBorder(TF.stroke, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: TF.radius, style: .continuous))
                    .padding(7)
                detail
                    .frame(minWidth: 380)
                    .background(TF.panel, in: RoundedRectangle(cornerRadius: TF.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: TF.radius, style: .continuous).strokeBorder(TF.stroke, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: TF.radius, style: .continuous))
                    .padding(7)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
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
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TFSearchField(text: $search, placeholder: "过滤 URL / 主机", width: 210, focus: $searchFocused)

            Spacer()

            Text(paused ? "已暂停 · \(source.count) 条" : "\(engine.captures.count) 条")
                .font(TFFont.num(10.5, weight: .medium))
                .foregroundStyle(paused ? TF.amber : TF.textTertiary)
                .fixedSize()

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
                    Text(paused ? "继续" : "暂停").font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(TFGhostButtonStyle())
            .help(paused ? "恢复实时刷新" : "冻结当前列表，便于阅读")
            .disabled(engine.captures.isEmpty && !paused)

            Toggle(isOn: Binding(
                get: { engine.profile.general.mitmEnabled },
                set: { enabled in
                    if enabled { showMITMWarning = true }
                    engine.setMITMEnabled(enabled)
                }
            )) {
                Text("HTTPS 解密").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Button { exportHAR() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 9, weight: .bold))
                    Text("导出 HAR").font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(TFGhostButtonStyle())
            .disabled(engine.captures.isEmpty)

            Button { showClearConfirm = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash").font(.system(size: 9, weight: .bold))
                    Text("清空").font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(TFGhostButtonStyle())
            .disabled(engine.captures.isEmpty && engine.flows.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 11)
    }

    private var filterRow: some View {
        HStack(spacing: 5) {
            ForEach(StatusFilter.allCases) { option in
                TFChip(title: option.title, selected: statusFilter == option) {
                    withAnimation(.easeOut(duration: 0.12)) { statusFilter = option }
                }
            }
            Spacer()
            if !search.isEmpty || statusFilter != .all {
                Text("\(filtered.count) / \(source.count)")
                    .font(TFFont.num(10, weight: .medium))
                    .foregroundStyle(TF.textTertiary)
                Button("清除筛选") {
                    search = ""
                    statusFilter = .all
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(TF.accent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 9)
    }

    private var list: some View {
        Group {
            if filtered.isEmpty {
                TFEmptyState(
                    icon: "waveform.path.ecg",
                    title: engine.profile.general.captureEnabled ? "暂无 HTTP 请求" : "抓包已在设置中关闭",
                    message: engine.profile.general.captureEnabled
                        ? "启动代理并把应用流量指向 127.0.0.1:\(engine.profile.general.mixedPort) 后即可看到明文请求；HTTPS 需开启解密。"
                        : "到设置页打开“抓包”后再回来。",
                    actionTitle: engine.profile.general.captureEnabled ? nil : "打开设置",
                    action: engine.profile.general.captureEnabled ? nil : { app.go(to: .settings) })
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
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

    private func captureRow(_ request: CapturedRequest) -> some View {
        HStack(spacing: 9) {
            Text(request.method)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .frame(width: 32)
                .padding(.vertical, 3)
                .background(methodColor(request.method).opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .foregroundStyle(methodColor(request.method))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if request.blocked {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(TF.danger)
                    }
                    Text(request.host)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TF.text)
                        .lineLimit(1)
                }
                Text(path(request.url))
                    .font(TFFont.mono(9.5))
                    .foregroundStyle(TF.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let code = request.statusCode {
                Text(String(code))
                    .font(TFFont.num(10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((code < 400 ? TF.success : TF.danger).opacity(0.13),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(code < 400 ? TF.success : TF.danger)
            }
            Text(Fmt.duration(request.durationMs))
                .font(TFFont.num(9.5))
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
                            Text(req.url).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
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
                        HStack(spacing: 12) {
                            if let code = req.statusCode { Badge(text: "\(code)", color: code < 400 ? .green : .red) }
                            if let mime = req.mimeType { Badge(text: mime, color: .blue) }
                            Badge(text: Fmt.clock(req.timestamp), color: .gray)
                            Badge(text: Fmt.duration(req.durationMs), color: .gray)
                            if req.blocked { Badge(text: "已拦截", color: .red) }
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
