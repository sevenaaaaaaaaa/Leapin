import SwiftUI
import TouchFlowCore
import TouchFlowRuntime
import TouchFlowPolicy
import TouchFlowNet
import TouchFlowIntegrations

@MainActor
struct AdBlockView: View {
    @ObservedObject private var engine = TouchFlowEngine.shared
    @State private var probe = ""
    @State private var result: BlockVerdict?
    @State private var allowText = ""
    @State private var loadedAllow = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    StatTile(icon: "hand.raised.fill", title: "过滤规则",
                             value: "\(engine.adblockRuleCount)", tint: TF.danger,
                             caption: "ABP / hosts 规则总数")
                    StatTile(icon: "nosign", title: "已拦截请求",
                             value: "\(engine.stats.blocked)", tint: TF.amber,
                             caption: "本次会话累计")
                    StatTile(icon: "eye.slash", title: "元素隐藏",
                             value: engine.profile.adblock.cosmeticFiltering ? "已开启" : "关闭", tint: TF.violet,
                             caption: "注入 CSS 隐藏规则")
                }

                Card(title: "去广告引擎", subtitle: engine.adblockActive ? "运行中" : "未加载", icon: "hand.raised") {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(engine.profile.adblock.enabled ? TF.danger.opacity(0.14) : TF.stroke.opacity(0.6))
                            Image(systemName: engine.profile.adblock.enabled ? "hand.raised.fill" : "hand.raised.slash")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(engine.profile.adblock.enabled ? TF.danger : TF.textTertiary)
                        }
                        .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("启用广告与跟踪器拦截")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(TF.text)
                            Text("关闭后所有域名直接放行，规则分流仍然生效")
                                .font(.system(size: 10))
                                .foregroundStyle(TF.textTertiary)
                        }
                        Spacer()
                        TFSwitch(isOn: Binding(
                            get: { engine.profile.adblock.enabled },
                            set: { engine.setAdBlockEnabled($0) }
                        ))
                    }

                    TFDivider().opacity(0.6)

                    HStack(spacing: 18) {
                        subToggle("跟踪器名单", engine.profile.adblock.blockTrackers) { v in
                            engine.updateProfile(restart: true) { $0.adblock.blockTrackers = v }
                        }
                        subToggle("hosts 语法", engine.profile.adblock.hostsBlocking) { v in
                            engine.updateProfile(restart: true) { $0.adblock.hostsBlocking = v }
                        }
                        subToggle("元素隐藏", engine.profile.adblock.cosmeticFiltering) { v in
                            engine.updateProfile(restart: false) { $0.adblock.cosmeticFiltering = v }
                        }
                        Spacer(minLength: 0)
                    }
                }

                Card(title: "拦截测试", subtitle: "输入域名验证是否命中广告规则", icon: "testtube.2") {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 10))
                                .foregroundStyle(TF.textTertiary)
                            TextField("doubleclick.net", text: $probe)
                                .textFieldStyle(.plain)
                                .font(TFFont.mono(11))
                                .onSubmit(run)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(TF.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                        Button("检查", action: run)
                            .buttonStyle(TFPrimaryButtonStyle())
                            .disabled(probe.isEmpty)
                    }
                    if let result {
                        HStack(spacing: 8) {
                            Image(systemName: result.blocked ? "xmark.octagon.fill" : "checkmark.seal.fill")
                                .foregroundStyle(result.blocked ? TF.danger : TF.mint)
                            Text(result.blocked ? "已拦截" : "放行")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(TF.text)
                            if let reason = result.reason {
                                Text(reason)
                                    .font(TFFont.mono(10))
                                    .foregroundStyle(TF.textSecondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(TF.stroke.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    blockLists
                    allowList
                }
            }
            .pagePadding()
        }
        .navigationTitle("去广告")
        .onAppear {
            guard !loadedAllow else { return }
            allowText = engine.profile.adblock.allowList.joined(separator: "\n")
            loadedAllow = true
        }
    }

    private var blockLists: some View {
        Card(title: "过滤列表", subtitle: "\(engine.profile.adblock.blockLists.count) 个来源", icon: "doc.text") {
            if engine.profile.adblock.blockLists.isEmpty {
                Text("使用内置 touchflow-ads.txt（约 100 条起步名单）")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(engine.profile.adblock.blockLists, id: \.self) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.hasPrefix("http") ? "link" : "doc.text")
                            .font(.system(size: 10))
                            .foregroundStyle(TF.accent)
                        Text(item)
                            .font(TFFont.mono(10))
                            .foregroundStyle(TF.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button {
                            engine.updateProfile(restart: true) { $0.adblock.blockLists.removeAll { $0 == item } }
                        } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(TF.textTertiary)
                    }
                    .padding(.vertical, 4)
                    TFDivider().opacity(0.5)
                }
            }
            Text("支持 ABP（||domain^、@@ 例外、$third-party）与 hosts 行。规则集/名单在启动时加载，10 万条以内可秒级完成。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var allowList: some View {
        Card(title: "白名单", subtitle: "每行一个域名，优先级最高", icon: "checkmark.shield") {
            TextEditor(text: $allowText)
                .font(TFFont.mono(10.5))
                .frame(height: 156)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(TF.stroke.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack {
                Spacer()
                Button("保存白名单") {
                    let list = allowText.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    engine.updateProfile(restart: true) { $0.adblock.allowList = list }
                }
                .buttonStyle(TFPrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func subToggle(_ label: String, _ isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            TFSwitch(isOn: Binding(get: { isOn }, set: set), width: 30)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(isOn ? TF.textSecondary : TF.textTertiary)
        }
    }

    private func run() {
        let domain = probe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty else { return }
        result = engine.adblockVerdict(domain: domain)
    }
}
