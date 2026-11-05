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
                             value: "\(engine.adblockRuleCount)", tint: .red)
                    StatTile(icon: "nosign", title: "已拦截请求",
                             value: "\(engine.stats.blocked)", tint: .orange)
                    StatTile(icon: "eye.slash", title: "元素隐藏",
                             value: engine.profile.adblock.cosmeticFiltering ? "开" : "关", tint: .purple)
                }

                Card(title: "去广告引擎", subtitle: engine.adblockActive ? "运行中" : "未加载", icon: "hand.raised") {
                    Toggle(isOn: Binding(
                        get: { engine.profile.adblock.enabled },
                        set: { engine.setAdBlockEnabled($0) }
                    )) {
                        Text("启用广告与跟踪器拦截").font(.callout)
                    }
                    .toggleStyle(.switch)

                    HStack(spacing: 16) {
                        Toggle("跟踪器名单", isOn: Binding(
                            get: { engine.profile.adblock.blockTrackers },
                            set: { v in engine.updateProfile(restart: true) { $0.adblock.blockTrackers = v } }
                        ))
                        Toggle("hosts 语法", isOn: Binding(
                            get: { engine.profile.adblock.hostsBlocking },
                            set: { v in engine.updateProfile(restart: true) { $0.adblock.hostsBlocking = v } }
                        ))
                        Toggle("元素隐藏", isOn: Binding(
                            get: { engine.profile.adblock.cosmeticFiltering },
                            set: { v in engine.updateProfile(restart: false) { $0.adblock.cosmeticFiltering = v } }
                        ))
                    }
                    .toggleStyle(.switch).controlSize(.small).font(.caption)

                    if !engine.profile.adblock.enabled {
                        Text("关闭后所有域名直接放行，规则分流仍然生效。").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Card(title: "拦截测试", subtitle: "输入域名验证是否命中广告规则", icon: "testtube.2") {
                    HStack {
                        TextField("doubleclick.net", text: $probe)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(run)
                        Button("检查", action: run).disabled(probe.isEmpty)
                    }
                    if let result {
                        HStack(spacing: 8) {
                            Image(systemName: result.blocked ? "xmark.octagon.fill" : "checkmark.seal.fill")
                                .foregroundStyle(result.blocked ? .red : .green)
                            Text(result.blocked ? "已拦截" : "放行").font(.callout.weight(.medium))
                            if let reason = result.reason {
                                Text(reason).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
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
                    HStack {
                        Image(systemName: item.hasPrefix("http") ? "link" : "doc")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(item).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            engine.updateProfile(restart: true) { $0.adblock.blockLists.removeAll { $0 == item } }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
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
                .font(.caption.monospaced())
                .frame(height: 150)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("保存白名单") {
                    let list = allowText.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    engine.updateProfile(restart: true) { $0.adblock.allowList = list }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func run() {
        let domain = probe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty else { return }
        result = engine.adblockVerdict(domain: domain)
    }
}
