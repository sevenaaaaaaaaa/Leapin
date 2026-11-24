import SwiftUI
import LeapinRuntime

/// First run starts with a goal, rather than a lesson in network architecture.
@MainActor
struct OnboardingView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                LPEyebrow("WELCOME / LEAPIN")
                Spacer()
                Button("稍后设置") { finish() }.buttonStyle(LPGhostButtonStyle())
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("先做成一件事。")
                    .font(LPFont.display(28, weight: .semibold)).foregroundStyle(LP.text)
                Text("从总览选择场景，管理订阅、网站和设备。需要检查时，再进入排障工作区。")
                    .font(.system(size: 14)).foregroundStyle(LP.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 同一「路」的第一次亮相：不写任何实时数字，只讲这台机器怎么想事情。
            RouteLine(nodes: [
                .init("你的请求", subtitle: "任意一个网站"),
                .init("命中规则", subtitle: "按配置判一次"),
                .init("出口", subtitle: "直连或节点", state: .current),
            ], onInk: false)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 14) {
                Label("连接网络：启动服务，再自动接入系统代理", systemImage: "network")
                Label("网站打不开：检查规则、DNS 与网站响应", systemImage: "stethoscope")
                Label("调整分流：预览具体修改，随时撤销", systemImage: "arrow.uturn.backward")
            }
            .font(.system(size: 13)).foregroundStyle(LP.text)
            LPDivider()
            Text("使用当前配置连接。Leapin 不提供代理节点；需要远程代理时，请先导入已有配置。系统代理仅适用于支持它的 App。")
                .font(.system(size: 13)).foregroundStyle(LP.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("连接网络") {
                    finish()
                    app.go(to: .dashboard)
                    app.connectNetwork()
                }
                .buttonStyle(LPPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                Button("我有配置文件") {
                    finish()
                    app.beginImport()
                }.buttonStyle(LPGhostButtonStyle())
                Spacer()
            }
            HStack(spacing: 8) {
                LPKeyCap(keys: "⌘K")
                Text("随时查找任务和专业工具").font(.system(size: 13)).foregroundStyle(LP.textTertiary)
            }
        }
        .padding(28).frame(width: 580)
        .preferredColorScheme(ProcessInfo.processInfo.environment["LEAPIN_APPEARANCE"] == "dark" ? .dark : nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "lp.onboarded")
        app.showOnboarding = false
    }
}
