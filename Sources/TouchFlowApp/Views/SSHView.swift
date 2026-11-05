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

    var body: some View {
        VStack(spacing: 0) {
            form
            terminal
        }
        .onDisappear {
            Task { await session.disconnect() }
        }
    }

    private var form: some View {
        Card(title: "连接", subtitle: "支持密码或私钥，密码经 SSH_ASKPASS 传入，不上命令行", icon: "terminal") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    fieldLabel("主机")
                    TextField("主机名或 IP", text: $host)
                        .textFieldStyle(.plain)
                        .font(TFFont.mono(11.5))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(TF.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .frame(minWidth: 180)
                    fieldLabel("端口")
                    TextField("22", text: $port)
                        .textFieldStyle(.plain)
                        .font(TFFont.mono(11.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(TF.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .frame(width: 62)
                    fieldLabel("用户")
                    TextField("用户名", text: $user)
                        .textFieldStyle(.plain)
                        .font(TFFont.mono(11.5))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(TF.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .frame(width: 130)
                }

                HStack(spacing: 10) {
                    Picker("", selection: $useKey) {
                        Text("密码").tag(false)
                        Text("密钥").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 120)

                    if useKey {
                        TextField("私钥路径", text: $keyPath)
                            .textFieldStyle(.plain)
                            .font(TFFont.mono(11))
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(TF.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Button("选择…") { pickKey() }
                            .buttonStyle(TFGhostButtonStyle())
                    } else {
                        SecureField("密码", text: $password)
                            .textFieldStyle(.plain)
                            .font(TFFont.mono(11))
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(TF.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .frame(width: 180)
                        Toggle("记住密码", isOn: $remember)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                    }

                    Spacer(minLength: 8)

                    if connected {
                        Button {
                            Task {
                                await session.disconnect()
                                connected = false
                                output += "\n[已断开]\n"
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "bolt.slash").font(.system(size: 9, weight: .bold))
                                Text("断开").font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .buttonStyle(TFPrimaryButtonStyle(tint: TF.danger))
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
                    Text(errorText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(TF.danger)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 16)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(TF.textTertiary)
    }

    private var terminal: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 9, height: 9)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 9, height: 9)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.42)).frame(width: 9, height: 9)
                Text(connected ? "\(user)@\(host):\(port)" : "ssh — 未连接")
                    .font(TFFont.mono(10.5, weight: .medium))
                    .foregroundStyle(Color(red: 0.62, green: 0.68, blue: 0.78))
                    .padding(.leading, 6)
                Spacer()
                Text(connected ? "LIVE" : "IDLE")
                    .font(TFFont.mono(8.5, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(connected ? Color(red: 0.22, green: 0.88, blue: 0.62) : Color(red: 0.45, green: 0.50, blue: 0.58))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color(red: 0.07, green: 0.09, blue: 0.13))

            ScrollViewReader { proxy in
                ScrollView {
                    Text(clean(output.isEmpty ? "连接后在此显示终端输出。支持交互式 shell（ssh -tt）。\n" : output))
                        .font(TFFont.mono(11.5))
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
                    .font(TFFont.mono(12, weight: .bold))
                    .foregroundStyle(Color(red: 0.22, green: 0.88, blue: 0.62))
                TextField("", text: $command, prompt: Text("输入命令，回车发送").foregroundColor(Color(red: 0.42, green: 0.50, blue: 0.60)))
                    .textFieldStyle(.plain)
                    .font(TFFont.mono(11.5))
                    .foregroundStyle(Color(red: 0.85, green: 0.90, blue: 0.97))
                    .onSubmit(send)
                    .disabled(!connected)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color(red: 0.06, green: 0.075, blue: 0.11))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(TF.strokeStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .padding(.horizontal, 26)
        .padding(.top, 14)
        .padding(.bottom, 20)
    }

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
            } catch {
                errorText = error.localizedDescription
                output += "\n[连接失败] \(error.localizedDescription)\n"
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
