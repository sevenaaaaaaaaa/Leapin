import SwiftUI
import AppKit
import TouchFlowCore
import TouchFlowRuntime
import TouchFlowPolicy
import TouchFlowNet
import TouchFlowIntegrations

@MainActor
struct AdBlockView: View {
    @ObservedObject private var engine = TouchFlowEngine.shared
    @EnvironmentObject private var app: AppModel
    @State private var probe = ""
    @State private var result: BlockVerdict?
    @State private var allowText = ""
    @State private var loadedAllow = false
    @State private var newList = ""
    @State private var showAllowConfirm = false
    @State private var pendingAllowList: [String] = []
    @FocusState private var probeFocused: Bool

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
                            set: { value in
                                engine.setAdBlockEnabled(value)
                                app.showToast(value ? "去广告已开启" : "去广告已关闭", kind: value ? .success : .info)
                            }
                        ))
                    }

                    TFDivider().opacity(0.6)

                    HStack(spacing: 18) {
                        subToggle("跟踪器名单", Binding(
                            get: { engine.profile.adblock.blockTrackers },
                            set: { v in engine.updateProfile(restart: true) { $0.adblock.blockTrackers = v } }
                        ))
                        subToggle("hosts 语法", Binding(
                            get: { engine.profile.adblock.hostsBlocking },
                            set: { v in engine.updateProfile(restart: true) { $0.adblock.hostsBlocking = v } }
                        ))
                        subToggle("元素隐藏", Binding(
                            get: { engine.profile.adblock.cosmeticFiltering },
                            set: { v in engine.updateProfile(restart: false) { $0.adblock.cosmeticFiltering = v } }
                        ))
                        Spacer(minLength: 0)
                    }
                }

                Card(title: "拦截测试", subtitle: "输入域名验证是否命中广告规则（仅按域名判定，不看路径）", icon: "testtube.2") {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 10))
                                .foregroundStyle(TF.textTertiary)
                            TextField("doubleclick.net", text: $probe)
                                .textFieldStyle(.plain)
                                .font(TFFont.mono(11))
                                .focused($probeFocused)
                                .onSubmit(run)
                            if !probe.isEmpty {
                                Button { probe = ""; result = nil } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(TF.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(TF.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(probeFocused ? TF.accent.opacity(0.6) : .clear, lineWidth: 1))

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
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Button {
                                TFClipboard.copy(result.blocked ? "blocked" : "allowed")
                                app.showToast("已复制结论", kind: .info)
                            } label: {
                                Image(systemName: "doc.on.doc").font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(TF.textTertiary)
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
        .onChange(of: app.searchFocusRequest) { _, _ in probeFocused = true }
        .tfConfirm("覆盖现有白名单？",
                   message: "保存会用编辑器中的 \(pendingAllowList.count) 条替换当前白名单，此操作可在提示条中撤销。",
                   isPresented: $showAllowConfirm,
                   confirmTitle: "覆盖保存") {
            applyAllowList(pendingAllowList)
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
                            app.showToast("已移除来源", kind: .info, actionTitle: "撤销") {
                                engine.updateProfile(restart: true) { profile in
                                    if !profile.adblock.blockLists.contains(item) {
                                        profile.adblock.blockLists.append(item)
                                    }
                                }
                            }
                        } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(TF.textTertiary)
                            .help("移除来源")
                    }
                    .padding(.vertical, 4)
                    TFDivider().opacity(0.5)
                }
            }

            HStack(spacing: 6) {
                TextField("https://… 或本地文件路径", text: $newList)
                    .textFieldStyle(.plain)
                    .font(TFFont.mono(10))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(TF.stroke.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Button("添加") {
                    let value = newList.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return }
                    guard !engine.profile.adblock.blockLists.contains(value) else {
                        app.showToast("该来源已存在", kind: .warning)
                        return
                    }
                    engine.updateProfile(restart: true) { $0.adblock.blockLists.append(value) }
                    newList = ""
                    app.showToast("已添加来源，正在重新加载", kind: .success)
                }
                .buttonStyle(TFGhostButtonStyle())
                .disabled(newList.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 6)

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
                Text("\(allowText.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count) 条")
                    .font(TFFont.num(9.5))
                    .foregroundStyle(TF.textTertiary)
                Spacer()
                Button("保存白名单") {
                    let list = allowText.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    // 整份覆盖前先确认，避免误删已有白名单。
                    if !engine.profile.adblock.allowList.isEmpty, engine.profile.adblock.allowList != list {
                        pendingAllowList = list
                        showAllowConfirm = true
                    } else {
                        applyAllowList(list)
                    }
                }
                .buttonStyle(TFPrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func subToggle(_ label: String, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            TFSwitch(isOn: isOn, width: 30)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(isOn.wrappedValue ? TF.textSecondary : TF.textTertiary)
        }
    }

    private func applyAllowList(_ list: [String]) {
        let previous = engine.profile.adblock.allowList
        engine.updateProfile(restart: true) { $0.adblock.allowList = list }
        app.showToast("白名单已保存（\(list.count) 条）", kind: .success, actionTitle: "撤销") {
            engine.updateProfile(restart: true) { $0.adblock.allowList = previous }
            app.showToast("已恢复上一份白名单", kind: .info)
        }
    }

    private func run() {
        let domain = probe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty else { return }
        result = engine.adblockVerdict(domain: domain)
        if result == nil { app.showToast("无法解析该域名", kind: .warning) }
    }
}
