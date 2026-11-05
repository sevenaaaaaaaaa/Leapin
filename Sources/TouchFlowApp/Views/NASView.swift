import SwiftUI
import AppKit
import TouchFlowCore
import TouchFlowIntegrations
import TouchFlowPolicy
import TouchFlowNet
import TouchFlowRuntime

@MainActor
struct NASView: View {
    @EnvironmentObject private var app: AppModel
    @State private var discovery = NASDiscovery()
    @State private var devices: [NASDevice] = []
    @State private var scanning = false
    @State private var selected: NASDevice?
    @State private var share = ""
    @State private var user = NSUserName()
    @State private var password = ""
    @State private var remember = true
    @State private var busy = false
    @State private var manualHost = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "发现 NAS", subtitle: scanning ? "扫描中…" : "Bonjour / SMB 广播", icon: "dot.radiowaves.left.and.right") {
                    HStack {
                        Button {
                            toggleScan()
                        } label: {
                            Label(scanning ? "停止扫描" : "开始扫描", systemImage: scanning ? "stop.circle" : "antenna.radiowaves.left.and.right")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                        Spacer()
                        TextField("手动输入主机名 / IP", text: $manualHost)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                        Button("添加") {
                            let h = manualHost.trimmingCharacters(in: .whitespaces)
                            guard !h.isEmpty else { return }
                            let device = NASDevice(id: h, name: h, host: h, port: 445, service: "_smb._tcp", model: nil)
                            if !devices.contains(device) { devices.append(device) }
                            manualHost = ""
                        }
                    }
                    if devices.isEmpty {
                        Text("未发现设备。点击开始扫描，或手动输入 NAS 的 IP / 主机名。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !devices.isEmpty {
                    Card(title: "设备", subtitle: "\(devices.count) 台", icon: "externaldrive.connected.to.line.below") {
                        ForEach(devices) { device in
                            Button {
                                selected = device
                                if share.isEmpty { share = "home" }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "externaldrive.fill")
                                        .foregroundStyle(selected == device ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name).font(.callout)
                                        Text("\(device.host):\(device.port) · \(device.service)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let model = device.model { Badge(text: model, color: .blue) }
                                    if selected == device { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                                }
                                .padding(8)
                                .background(selected == device ? Color.accentColor.opacity(0.12) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Card(title: "连接共享", subtitle: selected.map { "\($0.name) · \($0.host)" } ?? "先选择设备", icon: "network.badge.shield.half.filled") {
                    if let device = selected {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                            GridRow {
                                Text("共享名").font(.callout).foregroundStyle(.secondary)
                                TextField("home / Media / Backup", text: $share).textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("用户名").font(.callout).foregroundStyle(.secondary)
                                TextField("用户名", text: $user).textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("密码").font(.callout).foregroundStyle(.secondary)
                                HStack {
                                    SecureField("密码", text: $password).textFieldStyle(.roundedBorder)
                                    Toggle("记住", isOn: $remember).toggleStyle(.checkbox).font(.caption)
                                }
                            }
                        }
                        .frame(maxWidth: 460)
                        HStack(spacing: 10) {
                            Button {
                                mount(device)
                            } label: { Label(busy ? "挂载中…" : "挂载", systemImage: "externaldrive.badge.plus") }
                                .buttonStyle(.borderedProminent)
                                .disabled(busy || share.isEmpty)
                            Button {
                                NSWorkspace.shared.open(URL(string: "smb://\(device.host)/\(share.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? share)")!)
                            } label: { Label("在 Finder 打开", systemImage: "folder") }
                            Button {
                                if let pw = Keychain.get(account: "smb:\(user)@\(device.host)") {
                                    password = pw
                                    app.toast = "已读取保存的密码"
                                }
                            } label: { Label("读取密码", systemImage: "key") }
                        }
                        if !password.isEmpty {
                            Text("凭据只保存在本机钥匙串（可选），不会写进配置文件或日志。")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("选择上方一台设备后即可挂载 SMB 共享").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .pagePadding()
        }
        .navigationTitle("NAS")
        .onDisappear { discovery.stop(); scanning = false }
    }

    private func toggleScan() {
        if scanning {
            discovery.stop()
            scanning = false
        } else {
            scanning = true
            devices.removeAll()
            discovery.start { list in
                Task { @MainActor in
                    devices = list
                }
            }
        }
    }

    private func mount(_ device: NASDevice) {
        busy = true
        let host = device.host, sh = share, u = user, pw = password
        Task {
            do {
                let url = try NASMounter.mountSMB(host: host, share: sh, user: u, password: pw)
                if remember, !pw.isEmpty { _ = Keychain.set(pw, account: "smb:\(u)@\(host)") }
                NSWorkspace.shared.activateFileViewerSelecting([url])
                app.toast = "已挂载 \(host)/\(sh)"
            } catch {
                app.toast = "挂载失败：\(error.localizedDescription)"
            }
            busy = false
        }
    }
}
