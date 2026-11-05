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
                    HStack(spacing: 10) {
                        Button {
                            toggleScan()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: scanning ? "stop.circle" : "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 9, weight: .bold))
                                Text(scanning ? "停止扫描" : "开始扫描")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .buttonStyle(TFPrimaryButtonStyle())
                        .disabled(busy)

                        Spacer()

                        HStack(spacing: 6) {
                            Image(systemName: "keyboard")
                                .font(.system(size: 10))
                                .foregroundStyle(TF.textTertiary)
                            TextField("", text: $manualHost, prompt: Text("手动输入主机名 / IP").foregroundColor(TF.textTertiary))
                                .textFieldStyle(.plain)
                                .font(TFFont.mono(11))
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(TF.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .frame(width: 244)

                        Button("添加") {
                            let h = manualHost.trimmingCharacters(in: .whitespaces)
                            guard !h.isEmpty else { return }
                            let device = NASDevice(id: h, name: h, host: h, port: 445, service: "_smb._tcp", model: nil)
                            if devices.contains(device) {
                                app.showToast("该设备已在列表中", kind: .warning)
                            } else {
                                devices.append(device)
                                selected = device
                                if share.isEmpty { share = "home" }
                                app.showToast("已添加 \(h)", kind: .success)
                            }
                            manualHost = ""
                        }
                        .buttonStyle(TFGhostButtonStyle())
                    }
                    if devices.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: scanning ? "dot.radiowaves.left.and.right" : "info.circle")
                                .font(.system(size: 10))
                            Text(scanning ? "正在扫描局域网中的 SMB 广播…" : "未发现设备。点击开始扫描，或手动输入 NAS 的 IP / 主机名。")
                                .font(.system(size: 10.5))
                        }
                        .foregroundStyle(scanning ? TF.amber : TF.textTertiary)
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
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(selected == device ? TF.accent.opacity(0.15) : TF.stroke.opacity(0.5))
                                        Image(systemName: "externaldrive.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(selected == device ? TF.accent : TF.textSecondary)
                                    }
                                    .frame(width: 26, height: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(TF.text)
                                        Text("\(device.host):\(device.port) · \(device.service)")
                                            .font(TFFont.mono(9.5))
                                            .foregroundStyle(TF.textTertiary)
                                    }
                                    Spacer(minLength: 8)
                                    if let model = device.model { Badge(text: model, color: TF.violet) }
                                    if selected == device {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(TF.accent)
                                    }
                                }
                                .padding(9)
                                .background(selected == device ? TF.accent.opacity(0.09) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Card(title: "连接共享", subtitle: selected.map { "\($0.name) · \($0.host)" } ?? "先选择设备", icon: "network.badge.shield.half.filled") {
                    if let device = selected {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow {
                                Text("共享名").font(.system(size: 11)).foregroundStyle(TF.textSecondary)
                                field($share, "home / Media / Backup", mono: false)
                            }
                            GridRow {
                                Text("用户名").font(.system(size: 11)).foregroundStyle(TF.textSecondary)
                                field($user, "用户名", mono: true)
                            }
                            GridRow {
                                Text("密码").font(.system(size: 11)).foregroundStyle(TF.textSecondary)
                                HStack(spacing: 10) {
                                    SecureField("密码", text: $password)
                                        .textFieldStyle(.plain)
                                        .font(TFFont.mono(11))
                                        .padding(.horizontal, 9).padding(.vertical, 6)
                                        .background(TF.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                        .frame(width: 220)
                                    Toggle("记住", isOn: $remember)
                                        .toggleStyle(.checkbox)
                                        .font(.system(size: 10.5))
                                }
                            }
                        }
                        .frame(maxWidth: 520)

                        HStack(spacing: 8) {
                            Button {
                                mount(device)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "externaldrive.badge.plus").font(.system(size: 9, weight: .bold))
                                    Text(busy ? "挂载中…" : "挂载").font(.system(size: 11, weight: .semibold))
                                }
                            }
                            .buttonStyle(TFPrimaryButtonStyle())
                            .disabled(busy || share.isEmpty)

                            Button("在 Finder 打开") {
                                let encoded = share.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? share
                                if let url = URL(string: "smb://\(device.host)/\(encoded)") {
                                    NSWorkspace.shared.open(url)
                                } else {
                                    app.showToast("无法构造 smb:// 地址", kind: .warning)
                                }
                            }
                            .buttonStyle(TFGhostButtonStyle())

                            Button("读取密码") {
                                if let pw = Keychain.get(account: "smb:\(user)@\(device.host)") {
                                    password = pw
                                    app.showToast("已读取保存的密码", kind: .info)
                                } else {
                                    app.showToast("钥匙串中没有该主机的密码", kind: .warning)
                                }
                            }
                            .buttonStyle(TFGhostButtonStyle())
                        }
                        if !password.isEmpty {
                            Text("凭据只保存在本机钥匙串（可选），不会写进配置文件或日志。")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    } else {
                        TFEmptyState(icon: "externaldrive.badge.questionmark",
                                     title: "还没有选择设备",
                                     message: devices.isEmpty ? "先扫描或手动添加一台 NAS，再选择它。" : "在上方设备列表中选择一台即可挂载。",
                                     actionTitle: devices.isEmpty ? (scanning ? nil : "开始扫描") : nil,
                                     action: devices.isEmpty && !scanning ? { toggleScan() } : nil)
                            .frame(height: 170)
                    }
                }

                Card(title: "挂载说明", subtitle: "SMB 走系统原生 mount_smbfs", icon: "info.circle") {
                    VStack(alignment: .leading, spacing: 7) {
                        tip("挂载点：~/Volumes/<共享名>，挂载后可直接在 Finder / 终端访问")
                        tip("凭据：勾选「记住」后写入钥匙串（smb:<用户>@<主机>），不写入配置文件")
                        tip("Bonjour 需要本地网络权限；若扫描不到，可直接输入 NAS 的 IP 手动添加")
                        tip("当前版本只支持 SMB（AFP / NFS 请用 Finder 的「连接服务器」）")
                    }
                }
            }
            .pagePadding()
        }
        .navigationTitle("NAS")
        .onDisappear { discovery.stop(); scanning = false }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(TF.textTertiary.opacity(0.55)).frame(width: 3.5, height: 3.5).padding(.top, 5)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(TF.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ text: Binding<String>, _ placeholder: String, mono: Bool) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(TF.textTertiary))
            .textFieldStyle(.plain)
            .font(mono ? TFFont.mono(11) : .system(size: 11.5))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(TF.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .frame(width: 260)
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
                    if list.isEmpty {
                        devices = list
                    } else {
                        let added = list.count - devices.count
                        devices = list
                        if added > 0 {
                            app.showToast("发现 \(list.count) 台设备", kind: .success)
                        }
                    }
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
                app.showToast("已挂载 \(host)/\(sh)", kind: .success)
            } catch {
                app.showToast("挂载失败：\(error.localizedDescription)", kind: .error)
            }
            busy = false
        }
    }
}
