import SwiftUI
import AppKit
import TouchFlowCore
import TouchFlowIntegrations
import TouchFlowPolicy
import TouchFlowNet
import TouchFlowRuntime

@MainActor
struct SSHView: View {
    @State private var host = ""
    @State private var port = "22"
    @State private var user = NSUserName()
    @State private var password = ""
    @State private var useKey = false
    @State private var keyPath = "~/.ssh/id_ed25519"
    @State private var remember = true
    @State private var session = SSHSession()
    @State private var connected = false
    @State private var connecting = false
    @State private var output = ""
    @State private var command = ""
    @State private var errorText: String?
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            form
                .padding(.horizontal, 32)
                .padding(.top, 22)
            terminal
                .padding(.horizontal, 32)
                .padding(.top, 22)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDisappear {
            Task { await session.disconnect() }
        }
        .navigationTitle("SSH")
    }

    // MARK: Form

    private var form: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "连接",
                          subtitle: "密码经 SSH_ASKPASS 传入，不上命令行",
                          icon: "terminal",
                          tint: TF.violet)
                .padding(18)

            TFDivider()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom, spacing: 12) {
                    field("主机 / HOST") {
                        TextField("主机名或 IP", text: $host)
                            .font(TFFont.mono(13))
                    }
                    .frame(minWidth: 200)

                    field("端口 / PORT") {
                        TextField("22", text: $port)
                            .font(TFFont.mono(13))
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: 92)

                    field("用户 / USER") {
                        TextField("用户名", text: $user)
                            .font(TFFont.mono(13))
                    }
                    .frame(width: 158)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    HStack(alignment: .bottom, spacing: 16) {
                        authTab("密码", active: !useKey) { useKey = false }
                        authTab("密钥", active: useKey) { useKey = true }
                    }
                    .padding(.bottom, 6)
                    .padding(.trailing, 6)

                    if useKey {
                        field("私钥 / KEY") {
                            TextField("私钥路径", text: $keyPath)
                                .font(TFFont.mono(12.5))
                        }
                        Button("选择…") { pickKey() }
                            .buttonStyle(TFGhostButtonStyle())
                    } else {
                        field(nil) {
                            SecureField("密码", text: $password)
                                .font(.system(size: 13))
                        }
                        .frame(width: 190)
                        HStack(spacing: 7) {
                            TFSwitch(isOn: $remember, width: 32)
                            Text("记住密码（Keychain）")
                                .font(.system(size: 12))
                                .foregroundStyle(TF.textSecondary)
                        }
                        .padding(.bottom, 7)
                    }

                    Spacer(minLength: 12)

                    if connected {
                        Button {
                            Task {
                                await session.disconnect()
                                connected = false
                                output += "\n[已断开]\n"
                                app.showToast("已断开 SSH 连接", kind: .info)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "bolt.slash").font(.system(size: 9, weight: .bold))
                                Text("断开").font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .buttonStyle(TFPrimaryButtonStyle(tint: TF.dangerFill))
                    } else {
                        Button {
                            connect()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                                Text(connecting ? "连接中…" : "连接").font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .buttonStyle(TFPrimaryButtonStyle())
                        .disabled(connecting || host.isEmpty)
                    }
                }

                if let errorText {
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(TF.danger).frame(width: 5, height: 5).padding(.top, 5)
                        Text(errorText)
                            .font(.system(size: 12))
                            .foregroundStyle(TF.danger)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(18)
        }
        .tfPanel(padding: 0)
    }

    private func field<Content: View>(_ label: String?, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .font(TFFont.mono(9))
                    .tracking(1.2)
                    .foregroundStyle(TF.textTertiary)
            }
            content()
                .textFieldStyle(.plain)
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(TF.stroke).frame(height: 1)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func authTab(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? TF.text : TF.textTertiary)
                Rectangle()
                    .fill(active ? TF.accent : Color.clear)
                    .frame(height: 1.5)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    // MARK: Terminal

    private var terminal: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Text(connected ? "\(user)@\(host):\(port)" : "ssh — 未连接")
                    .font(TFFont.mono(11, weight: .medium))
                    .tracking(0.3)
                    .foregroundStyle(Color(red: 0.72, green: 0.78, blue: 0.86))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if !output.isEmpty {
                    Button {
                        TFClipboard.copy(clean(output))
                        app.showToast("已复制终端输出", kind: .info)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(red: 0.62, green: 0.68, blue: 0.78))
                    }
                    .buttonStyle(.plain)
                    .help("复制全部输出")
                    .accessibilityLabel("复制全部终端输出")

                    Button {
                        output = ""
                    } label: {
                        Image(systemName: "eraser")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(red: 0.62, green: 0.68, blue: 0.78))
                    }
                    .buttonStyle(.plain)
                    .help("清空输出")
                    .accessibilityLabel("清空终端输出")
                }

                Circle()
                    .fill(connected ? TF.mint : Color(red: 0.45, green: 0.50, blue: 0.58))
                    .frame(width: 5, height: 5)

                Text(connected ? "LIVE" : "IDLE")
                    .font(TFFont.mono(9, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(connected ? TF.mint : Color(red: 0.45, green: 0.50, blue: 0.58))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(red: 0.07, green: 0.09, blue: 0.13))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(clean(output.isEmpty ? "连接后在此显示终端输出。支持交互式 shell（ssh -tt）。\n" : output))
                        .font(TFFont.mono(12))
                        .foregroundStyle(Color(red: 0.78, green: 0.86, blue: 0.95))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .id("bottom")
                }
                .background(Color(red: 0.04, green: 0.055, blue: 0.08))
                .onChange(of: output) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                Text("$")
                    .font(TFFont.mono(12.5, weight: .bold))
                    .foregroundStyle(TF.mint)
                TextField("", text: $command, prompt: Text("输入命令，回车发送").foregroundColor(Color(red: 0.42, green: 0.50, blue: 0.60)))
                    .textFieldStyle(.plain)
                    .font(TFFont.mono(12.5))
                    .foregroundStyle(Color(red: 0.85, green: 0.90, blue: 0.97))
                    .onSubmit(send)
                    .disabled(!connected)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(red: 0.06, green: 0.075, blue: 0.11))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TF.strokeStrong, lineWidth: 1)
        )
        .frame(minHeight: 240)
    }

    // MARK: Actions

    private func connect() {
        errorText = nil
        connecting = true
        let h = host.trimmingCharacters(in: .whitespaces)
        let p = UInt16(port) ?? 22
        let account = "ssh:\(user)@\(h)"
        if !useKey, remember, !password.isEmpty { _ = Keychain.set(password, account: account) }
        let pw: String? = useKey ? nil : password
        let key: String? = useKey ? (keyPath as NSString).expandingTildeInPath : nil

        Task {
            let s = SSHSession()
            await s.setOutputHandler { text in
                Task { @MainActor in
                    output += text
                    if output.count > 200_000 { output = String(output.suffix(120_000)) }
                }
            }
            do {
                try await s.connect(host: h, port: p, user: user, password: pw,
                                    keyPath: key, knownHosts: "accept-new")
                session = s
                connected = true
                errorText = nil
                output += "[已连接 \(user)@\(h):\(p)]\n"
                app.showToast("已连接 \(user)@\(h)", kind: .success)
            } catch {
                errorText = error.localizedDescription
                output += "\n[连接失败] \(error.localizedDescription)\n"
                app.showToast("连接失败：\(error.localizedDescription)", kind: .error)
            }
            connecting = false
        }
    }

    private func send() {
        guard !command.isEmpty else { return }
        let line = command
        command = ""
        output += line + "\n"
        Task { await session.write(line + "\n") }
    }

    private func pickKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: ("~/.ssh" as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { keyPath = url.path }
    }

    private func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[a-zA-Z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }
}
