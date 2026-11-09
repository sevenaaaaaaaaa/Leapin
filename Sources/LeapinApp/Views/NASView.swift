import SwiftUI
import AppKit
import LeapinCore
import LeapinIntegrations
import LeapinPolicy
import LeapinNet
import LeapinRuntime

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
            VStack(spacing: 22) {
                discoveryCard
                if !devices.isEmpty { devicesCard }
                connectCard
                mountNotes
            }
            .pagePadding()
        }
        .navigationTitle("NAS")
        .onDisappear { discovery.stop(); scanning = false }
    }

    // MARK: Discovery

    private var discoveryCard: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "发现 NAS",
                          subtitle: scanning ? "扫描中…" : "Bonjour / SMB 广播",
                          icon: "dot.radiowaves.left.and.right",
                          tint: scanning ? LP.amber : LP.textTertiary)
                .padding(18)

            LPDivider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        toggleScan()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: scanning ? "stop.circle" : "antenna.radiowaves.left.and.right")
                                .font(.system(size: 9, weight: .bold))
                            Text(scanning ? "停止扫描" : "开始扫描")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .buttonStyle(LPPrimaryButtonStyle())
                    .disabled(busy)

                    Spacer(minLength: 12)

                    HStack(spacing: 6) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 10))
                            .foregroundStyle(LP.textTertiary)
                        TextField("", text: $manualHost, prompt: Text("手动输入主机名 / IP").foregroundColor(LP.textTertiary))
                            .textFieldStyle(.plain)
                            .font(LPFont.mono(12))
                            .onSubmit(addManual)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .lpGlass(in: Capsule(style: .continuous),
                             fallbackFill: LP.panelSolid,
                             fallbackMaterial: .thinMaterial)
                    .frame(width: 250)

                    Button("添加", action: addManual)
                        .buttonStyle(LPGhostButtonStyle())
                        .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(scanning ? LP.amber : LP.textTertiary)
                        .frame(width: 5, height: 5)
                    Text(scanning ? "正在扫描局域网中的 SMB 广播…" : "未发现设备？点开始扫描，或手动输入 NAS 的 IP / 主机名。")
                        .font(.system(size: 12))
                        .foregroundStyle(scanning ? LP.amber : LP.textTertiary)
                }
            }
            .padding(18)
        }
        .lpPanel(padding: 0)
    }

    // MARK: Devices

    private var devicesCard: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "设备",
                          subtitle: "\(devices.count) 台",
                          icon: "externaldrive.connected.to.line.below")
                .padding(18)

            LPDivider()

            VStack(spacing: 0) {
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    Button {
                        selected = device
                        if share.isEmpty { share = "home" }
                    } label: {
                        HStack(spacing: 11) {
                            Rectangle()
                                .fill(selected == device ? LP.accent : Color.clear)
                                .frame(width: 2, height: 26)

                            Image(systemName: "externaldrive")
                                .font(.system(size: 12))
                                .foregroundStyle(LP.textSecondary)
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(LP.text)
                                Text("\(device.host):\(device.port) · \(device.service)")
                                    .font(LPFont.mono(10))
                                    .foregroundStyle(LP.textTertiary)
                            }

                            Spacer(minLength: 8)

                            if let model = device.model {
                                Badge(text: model, color: LP.textSecondary)
                            }
                            if selected == device {
                                Text("已选择")
                                    .font(LPFont.mono(10))
                                    .tracking(1)
                                    .foregroundStyle(LP.textTertiary)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(device.name)，\(device.host)，\(selected == device ? "已选择" : "点按选择")")

                    if index < devices.count - 1 {
                        LPDivider().padding(.leading, 31)
                    }
                }
            }
        }
        .lpPanel(padding: 0)
    }

    // MARK: Connect

    private var connectCard: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "连接共享",
                          subtitle: selected.map { "\($0.name) · \($0.host)" } ?? "先选择设备",
                          icon: "network.badge.shield.half.filled")
                .padding(18)

            LPDivider()

            if let device = selected {
                VStack(alignment: .leading, spacing: 14) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                        GridRow {
                            Text("共享名").font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                            field($share, "home / Media / Backup", mono: false)
                        }
                        GridRow {
                            Text("用户名").font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                            field($user, "用户名", mono: true)
                        }
                        GridRow {
                            Text("密码").font(.system(size: 12)).foregroundStyle(LP.textSecondary)
                            HStack(spacing: 10) {
                                SecureField("密码", text: $password)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 12)
                                    .frame(width: 220, height: 30)
                                    .lpGlass(in: Capsule(style: .continuous),
                                             fallbackFill: LP.panelSolid,
                                             fallbackMaterial: .thinMaterial)
                                Toggle("记住（钥匙串）", isOn: $remember)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 12))
                                    .foregroundStyle(LP.textSecondary)
                            }
                        }
                    }
                    .frame(maxWidth: 560, alignment: .leading)

                    HStack(spacing: 8) {
                        Button {
                            mount(device)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "externaldrive.badge.plus")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(LP.accent)
                                Text(busy ? "挂载中…" : "挂载")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .buttonStyle(LPGhostButtonStyle())
                        .disabled(busy || share.isEmpty)

                        Button("在 Finder 打开") {
                            let encoded = share.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? share
                            if let url = URL(string: "smb://\(device.host)/\(encoded)") {
                                NSWorkspace.shared.open(url)
                            } else {
                                app.showToast("无法构造 smb:// 地址", kind: .warning)
                            }
                        }
                        .buttonStyle(LPGhostButtonStyle())

                        Button("读取密码") {
                            if let pw = Keychain.get(account: "smb:\(user)@\(device.host)") {
                                password = pw
                                app.showToast("已读取保存的密码", kind: .info)
                            } else {
                                app.showToast("钥匙串中没有该主机的密码", kind: .warning)
                            }
                        }
                        .buttonStyle(LPGhostButtonStyle())
                    }

                    if !password.isEmpty {
                        Text("凭据只保存在本机钥匙串（可选），不会写进配置文件或日志。")
                            .font(.system(size: 12))
                            .foregroundStyle(LP.textTertiary)
                    }
                }
                .padding(18)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(LP.textTertiary)
                    Text("还没有选择设备")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LP.textSecondary)
                    Text(devices.isEmpty
                         ? "先在「发现 NAS」中扫描，或手动输入主机名添加设备；选中后这里会出现共享名与凭据表单。"
                         : "在上方设备列表中点选一台，再填写共享名与凭据。")
                        .font(.system(size: 12))
                        .foregroundStyle(LP.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 460, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
        }
        .lpPanel(padding: 0)
    }

    // MARK: Notes

    private var mountNotes: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "挂载说明",
                          subtitle: "SMB 走系统原生 mount_smbfs",
                          icon: "info.circle")
                .padding(18)

            LPDivider()

            VStack(spacing: 0) {
                note("挂载点：~/Volumes/<共享名>，挂载后可直接在 Finder / 终端访问")
                LPDivider()
                note("凭据：勾选「记住」后写入钥匙串（smb:<用户>@<主机>），不写入配置文件")
                LPDivider()
                note("Bonjour 需要本地网络权限；若扫描不到，可直接输入 NAS 的 IP 手动添加")
                LPDivider()
                note("当前版本只支持 SMB（AFP / NFS 请用 Finder 的「连接服务器」）")
            }
            .padding(.horizontal, 18)
        }
        .lpPanel(padding: 0)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(LP.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func field(_ text: Binding<String>, _ placeholder: String, mono: Bool) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(LP.textTertiary))
            .textFieldStyle(.plain)
            .font(mono ? LPFont.mono(12) : .system(size: 13))
            .padding(.horizontal, 12)
            .frame(width: 260, height: 30)
            .lpGlass(in: Capsule(style: .continuous),
                     fallbackFill: LP.panelSolid,
                     fallbackMaterial: .thinMaterial)
    }

    // MARK: Actions

    private func addManual() {
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
