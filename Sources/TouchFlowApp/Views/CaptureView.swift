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

    private var filtered: [CapturedRequest] {
        let q = search.lowercased()
        guard !q.isEmpty else { return engine.captures }
        return engine.captures.filter { $0.url.lowercased().contains(q) || $0.host.lowercased().contains(q) }
    }

    private var current: CapturedRequest? {
        engine.captures.first { $0.id == selected }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                list.frame(minWidth: 380)
                detail.frame(minWidth: 380)
            }
        }
        .navigationTitle("抓包")
        .alert("HTTPS 解密需要信任证书", isPresented: $showMITMWarning) {
            Button("去安装 CA") { app.installCA() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("开启后 TouchFlow 会用本地 CA 为 HTTPS 站点签发证书。请先把 touchflow-ca.pem 加入系统钥匙串并设为“始终信任”，否则客户端会报证书错误。")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("过滤 URL / 主机", text: $search).textFieldStyle(.plain)
            }
            .padding(6)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
            .frame(maxWidth: 300)

            Text("\(engine.captures.count) 条").font(.caption).foregroundStyle(.secondary)
            Spacer()

            Toggle("HTTPS 解密", isOn: Binding(
                get: { engine.profile.general.mitmEnabled },
                set: { enabled in
                    if enabled { showMITMWarning = true }
                    engine.setMITMEnabled(enabled)
                }
            ))
            .toggleStyle(.switch).controlSize(.small)

            Button { exportHAR() } label: { Label("导出 HAR", systemImage: "square.and.arrow.up") }
                .disabled(engine.captures.isEmpty)
            Button(role: .destructive) { engine.clearFlows() } label: { Label("清空", systemImage: "trash") }
                .disabled(engine.captures.isEmpty && engine.flows.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var list: some View {
        Group {
            if filtered.isEmpty {
                EmptyHint(icon: "waveform.path.ecg",
                          text: engine.profile.general.captureEnabled
                            ? "暂无 HTTP 请求。启动代理并把应用流量指向 127.0.0.1:\(engine.profile.general.mixedPort) 后即可看到明文请求；HTTPS 需开启解密。"
                            : "抓包已在设置中关闭")
            } else {
                List(selection: $selected) {
                    ForEach(filtered) { request in
                        HStack(spacing: 8) {
                            Text(request.method)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(methodColor(request.method).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(methodColor(request.method))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.host).font(.callout).lineLimit(1)
                                Text(path(request.url)).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let code = request.statusCode {
                                Text("\(code)").font(.caption.monospaced())
                                    .foregroundStyle(code < 400 ? .green : .red)
                            }
                            Text(Fmt.duration(request.durationMs)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .tag(request.id)
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var detail: some View {
        Group {
            if let req = current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Badge(text: req.method, color: methodColor(req.method))
                            Text(req.url).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
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
                EmptyHint(icon: "sidebar.right", text: "选择左侧请求查看详情、头部与正文")
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
            app.toast = "已导出 \(engine.captures.count) 条请求（敏感头已脱敏）"
        } catch {
            app.toast = "导出失败：\(error.localizedDescription)"
        }
    }
}
