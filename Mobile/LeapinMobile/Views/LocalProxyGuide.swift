import SwiftUI
import UIKit

/// 把这台手机的 Wi-Fi 代理指过来的引导。
///
/// iOS 不提供「自动接管」，也不需要付费账号：一次手动填地址，就能让系统流量
/// 经过本机引擎。这里只讲这一件事，讲完就让人去自检，不摆别的入口。
struct LocalProxyGuide: View {
    @Environment(\.dismiss) private var dismiss
    private var local: LocalProxyEngine { .shared }
    @State private var copied = false

    private var address: String { "127.0.0.1:" + String(local.port == 0 ? LocalProxyEngine.defaultPort : local.port) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LPCard(title: "填这个地址", subtitle: "服务器与端口分开填") {
                        HStack(spacing: 12) {
                            Text(address)
                                .font(LPFont.mono(22))
                                .foregroundStyle(LP.text)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Button {
                                UIPasteboard.general.string = address
                                copied = true
                            } label: {
                                Text(copied ? "已复制" : "复制")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(LP.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    LPCard(title: "五步设置", subtitle: "iOS 不会自动把流量交给 App") {
                        VStack(alignment: .leading, spacing: 10) {
                            step(1, "打开「设置」")
                            step(2, "无线局域网 → 当前网络右侧的 ⓘ")
                            step(3, "拉到底，点「配置代理」")
                            step(4, "选「手动」，服务器填 127.0.0.1，端口填 51003")
                            step(5, "点「存储」，回到这里跑一次自检")
                        }
                    }

                    LPCard(title: "确认生效", subtitle: local.lastCheck ?? "自检会经本机代理访问 example.com") {
                        Button {
                            Task { await local.selfCheck() }
                        } label: {
                            Text(local.isChecking ? "自检中…" : "我已设置好，跑一次自检")
                        }
                        .buttonStyle(LPButtonStyle())
                        .disabled(local.isChecking)
                    }

                    LPCard(title: "要回滚", subtitle: nil) {
                        Text("把「配置代理」改回「关闭」再存储，系统流量就恢复直连。这一步随时可做，不影响 App 里的引擎。")
                            .font(LPFont.micro)
                            .foregroundStyle(LP.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, LP.gutter)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .background(LP.canvas)
            .navigationTitle("Wi-Fi 代理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(index))
                .font(LPFont.mono(12))
                .foregroundStyle(LP.accent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(LP.accentSoft))
            Text(text)
                .font(LPFont.body)
                .foregroundStyle(LP.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
