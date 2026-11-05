import SwiftUI
import TouchFlowRuntime

/// Three-step first run. The goal is a working proxy in under a minute, with an exit at every step.
@MainActor
struct OnboardingView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var engine = TouchFlowEngine.shared
    @State private var step = 0

    private let steps: [(icon: String, title: String, body: String)] = [
        ("bolt.horizontal.circle", "启动本地代理",
         "TouchFlow 会在本机 :7890 提供混合代理（HTTP + SOCKS5），并可选启用 DNS。启动后你可以把任意 App 指向它。"),
        ("network", "接入系统网络",
         "开启系统代理后，macOS 的网络请求会自动经过 TouchFlow。随时可以在这里或菜单栏一键回滚。"),
        ("command", "用键盘完成一切",
         "⌘K 打开命令面板，⌘F 聚焦搜索，⌘1–⌘0 在十个页面之间跳转。菜单栏图标会常驻，关闭窗口也不会退出。"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("欢迎使用 TouchFlow")
                    .font(TFFont.display(19, weight: .bold))
                    .foregroundStyle(TF.text)
                Spacer()
                Button("跳过") { finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(TF.textTertiary)
            }
            .padding(.bottom, 4)

            Text("第 \(step + 1) / \(steps.count) 步")
                .font(TFFont.overline)
                .foregroundStyle(TF.textTertiary)
                .padding(.bottom, 16)

            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(TF.accentSoft)
                    Image(systemName: steps[step].icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(TF.accent)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 6) {
                    Text(steps[step].title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TF.text)
                    Text(steps[step].body)
                        .font(.system(size: 12))
                        .foregroundStyle(TF.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 380, alignment: .leading)
                }
            }
            .padding(.bottom, 18)

            stepAction
                .padding(.bottom, 18)

            HStack(spacing: 6) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? TF.accent : TF.stroke)
                        .frame(width: i == step ? 16 : 6, height: 4)
                }
                Spacer()
                if step > 0 {
                    Button("上一步") { TFMotion.run(TFMotion.quick) { step -= 1 } }
                        .buttonStyle(TFGhostButtonStyle())
                }
                Button(step == steps.count - 1 ? "开始使用" : "下一步") {
                    if step == steps.count - 1 { finish() }
                    else { TFMotion.run(TFMotion.quick) { step += 1 } }
                }
                .buttonStyle(TFPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(TF.panelSolid)
        .preferredColorScheme(ProcessInfo.processInfo.environment["TF_APPEARANCE"] == "dark" ? .dark : nil)
    }

    @ViewBuilder private var stepAction: some View {
        switch step {
        case 0:
            HStack(spacing: 10) {
                Button(engine.state == .running ? "代理已在运行" : "启动代理") {
                    app.toggle()
                }
                .buttonStyle(TFPrimaryButtonStyle())
                .disabled(engine.state == .running || engine.state == .starting)

                Text(engine.state == .running ? "已监听 127.0.0.1:\(engine.profile.general.mixedPort)" : "监听端口 \(engine.profile.general.mixedPort)")
                    .font(TFFont.mono(10))
                    .foregroundStyle(engine.state == .running ? TF.mint : TF.textTertiary)
            }
        case 1:
            HStack(spacing: 10) {
                Button(engine.systemProxyActive ? "关闭系统代理" : "开启系统代理") {
                    engine.toggleSystemProxy(!engine.systemProxyActive)
                }
                .buttonStyle(TFPrimaryButtonStyle(tint: engine.systemProxyActive ? TF.dangerFill : nil))

                Text(engine.systemProxyActive ? "系统代理已接管" : "当前未接管系统网络")
                    .font(.system(size: 10))
                    .foregroundStyle(engine.systemProxyActive ? TF.mint : TF.textTertiary)
            }
        default:
            HStack(spacing: 8) {
                TFKeyCap(keys: "⌘K")
                Text("随时唤起命令面板").font(.system(size: 10)).foregroundStyle(TF.textTertiary)
                TFKeyCap(keys: "⌘F").padding(.leading, 6)
                Text("搜索当前页面").font(.system(size: 10)).foregroundStyle(TF.textTertiary)
            }
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "tf.onboarded")
        app.showOnboarding = false
    }
}
