import SwiftUI
import LeapinCore

struct SettingsView: View {
    @Environment(ConsoleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDisconnect = false
    @AppStorage("lp.agent.draftBar") private var draftBarEnabled = true
    @AppStorage("lp.agent.confirmExit") private var confirmExit = false
    @AppStorage("lp.river.holdSeconds") private var holdSeconds = 3

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LPCard(title: "连接") {
                        VStack(spacing: 7) {
                            LPRow(key: "Mac 地址", value: store.endpoint?.displayAddress ?? "未连接", mono: true)
                            LPRow(key: "版本", value: store.status?.version ?? "—")
                            LPRow(key: "最近更新", value: LPFormat.timeAgo(store.lastUpdated))
                        }
                    }

                    LPCard(title: "刷新") {
                        Toggle(isOn: $store.autoRefresh) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("自动刷新")
                                    .font(LPFont.body)
                                    .foregroundStyle(LP.text)
                                Text("每 5 秒从 Mac 拉取状态")
                                    .font(LPFont.micro)
                                    .foregroundStyle(LP.textTertiary)
                            }
                        }
                        .tint(LP.accent)
                        .onChange(of: store.autoRefresh) { _, enabled in
                            if enabled { store.startPolling() }
                        }
                    }

                    LPCard(title: "Agent 与自动化") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $draftBarEnabled) {
                                settingLabel("草稿行", "在页面底部用一句话改网络")
                            }
                            .tint(LP.accent)

                            Toggle(isOn: $confirmExit) {
                                settingLabel("切换出口前确认", "影响所有走这条策略的连接")
                            }
                            .tint(LP.accent)

                            HStack(spacing: 10) {
                                settingLabel("回看保持", "时间河松手后回到实时前的等待")
                                Spacer(minLength: 8)
                                Picker("回看保持", selection: $holdSeconds) {
                                    Text("2 秒").tag(2)
                                    Text("3 秒").tag(3)
                                    Text("5 秒").tag(5)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 156)
                                .labelsHidden()
                            }
                        }
                    }

                    Button(role: .destructive) {
                        confirmDisconnect = true
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("断开并清除令牌")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Text("本机引擎在这台手机里跑，监听 127.0.0.1:51003；把系统代理指过来就能让流量经过它。系统级接管需要 NetworkExtension 权限（付费开发者账号），这版没有包含。Mac 是可选的配置源。")
                        .font(LPFont.micro)
                        .foregroundStyle(LP.textTertiary)
                        .padding(.horizontal, 2)
                }
                .lpPage()
            }
            .background(LP.canvas)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("断开后需要重新输入令牌", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("断开", role: .destructive) {
                    store.disconnect()
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func settingLabel(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(LPFont.body)
                .foregroundStyle(LP.text)
            Text(note)
                .font(LPFont.micro)
                .foregroundStyle(LP.textTertiary)
        }
    }
}
