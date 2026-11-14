import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// First-run pairing: the phone needs the Mac's address and control token.
/// Long tokens are pasted, never typed, so the field has a paste action.
struct SetupView: View {
    @Environment(ConsoleStore.self) private var store

    @State private var host = ""
    @State private var port = "7900"
    @State private var token = ""
    @State private var validationMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                LPCard(title: "连接 Mac", subtitle: "在同一个 Wi-Fi 下，控制本机的 Leapin") {
                    VStack(spacing: 10) {
                        field(title: "IP 地址", text: $host, placeholder: "192.168.1.10", keyboard: .numbersAndPunctuation)
                        field(title: "端口", text: $port, placeholder: "7900", keyboard: .numberPad)
                        tokenField
                    }
                }

                LPCard(title: "怎么拿到这些信息", subtitle: "在 Mac 上执行一次") {
                    VStack(alignment: .leading, spacing: 10) {
                        instruction(1, "让控制面监听局域网", "leapin control --lan")
                        instruction(2, "读取令牌", "cat ~/Library/Application\\ Support/Leapin/control-token")
                        instruction(3, "把 IP 和令牌填到这里", "IP 就是 Mac 在 Wi-Fi 里的地址")
                    }
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(LPFont.caption)
                        .foregroundStyle(LP.danger)
                        .padding(.horizontal, 2)
                }

                Button {
                    Task { await connect() }
                } label: {
                    HStack(spacing: 8) {
                        if store.isConnecting {
                            ProgressView().tint(.white).scaleEffect(0.8)
                        }
                        Text(store.isConnecting ? "正在连接…" : "连接")
                    }
                }
                .buttonStyle(LPButtonStyle())
                .disabled(store.isConnecting)

                Text("令牌保存在系统钥匙串，只用于访问你自己 Mac 的控制面。")
                    .font(LPFont.micro)
                    .foregroundStyle(LP.textTertiary)
                    .padding(.horizontal, 2)
            }
            .lpPage()
        }
        .background(LP.canvas)
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [LP.accent, LP.accent.opacity(0.7)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 26, height: 26)
                    .overlay(
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    )
                Text("Leapin")
                    .font(LPFont.display(20, weight: .semibold))
                    .foregroundStyle(LP.text)
            }
            Text("手机端控制台")
                .font(LPFont.caption)
                .foregroundStyle(LP.textTertiary)
        }
        .padding(.top, 8)
    }

    private func field(title: String, text: Binding<String>, placeholder: String,
                       keyboard: UIKeyboardType) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(LPFont.caption)
                .foregroundStyle(LP.textTertiary)
                .frame(width: 64, alignment: .leading)
            TextField(placeholder, text: text)
                .font(LPFont.mono(13))
                .foregroundStyle(LP.text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(LP.panelRaised, in: RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous)
                .strokeBorder(LP.stroke, lineWidth: 1)
        )
    }

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("令牌")
                    .font(LPFont.caption)
                    .foregroundStyle(LP.textTertiary)
                    .frame(width: 64, alignment: .leading)
                SecureField("粘贴 control-token", text: $token)
                    .font(LPFont.mono(13))
                    .foregroundStyle(LP.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    pasteFromClipboard()
                } label: {
                    Text("粘贴")
                        .font(LPFont.micro)
                        .foregroundStyle(LP.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(LP.panelRaised, in: RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous)
                    .strokeBorder(LP.stroke, lineWidth: 1)
            )
        }
    }

    private func instruction(_ index: Int, _ title: String, _ command: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(index)")
                .font(LPFont.micro)
                .foregroundStyle(LP.accent)
                .frame(width: 16, height: 16)
                .background(LP.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(LPFont.caption)
                    .foregroundStyle(LP.text)
                Text(command)
                    .font(LPFont.mono(11))
                    .foregroundStyle(LP.textTertiary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    private func pasteFromClipboard() {
        #if canImport(UIKit)
        if let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            token = value
            validationMessage = nil
        }
        #endif
    }

    private func connect() async {
        validationMessage = nil
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = "先填写 Mac 的 IP 地址"
            return
        }
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = "先粘贴 control-token"
            return
        }
        let ok = await store.connect(host: host, port: port, token: token)
        if !ok {
            validationMessage = store.lastError
        }
    }
}
