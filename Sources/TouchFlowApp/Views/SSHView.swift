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
            Divider()
            terminal
        }
        .navigationTitle("SSH")
        .onDisappear {
            Task { await session.disconnect() }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("主机名或 IP", text: $host)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                TextField("端口", text: $port)
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                TextField("用户名", text: $user)
                    .textFieldStyle(.roundedBorder).frame(width: 130)

                Picker("", selection: $useKey) {
                    Text("密码").tag(false)
                    Text("密钥").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 120)

                if useKey {
                    TextField("私钥路径", text: $keyPath).textFieldStyle(.roundedBorder)
                    Button("选择") { pickKey() }
                } else {
                    SecureField("密码", text: $password).textFieldStyle(.roundedBorder).frame(width: 160)
                    Toggle("记住", isOn: $remember).toggleStyle(.checkbox).font(.caption)
                }

                if connected {
                    Button(role: .destructive) {
                        Task {
                            await session.disconnect()
                            connected = false
                            output += "\n[已断开]\n"
                        }
                    } label: { Label("断开", systemImage: "bolt.slash") }
                } else {
                    Button {
                        connect()
                    } label: { Label(connecting ? "连接中" : "连接", systemImage: "bolt.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(connecting || host.isEmpty)
                }
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(16)
    }

    private var terminal: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(clean(output.isEmpty ? "连接后在此显示终端输出。支持交互式 shell（ssh -tt）。\n" : output))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: output) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                Text("$").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.green)
                TextField("输入命令，回车发送", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(send)
                    .disabled(!connected)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.quaternary.opacity(0.25))
        }
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
