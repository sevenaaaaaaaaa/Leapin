import SwiftUI
import LeapinCore

struct SettingsView: View {
    @Environment(ConsoleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDisconnect = false

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

                    Text("Leapin Mobile 只读取你自己 Mac 的控制面，不代理手机流量。手机上的系统级 VPN 需要 NetworkExtension 权限，这版没有包含。")
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
}
