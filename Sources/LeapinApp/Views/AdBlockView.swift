import SwiftUI
import AppKit
import LeapinCore
import LeapinRuntime
import LeapinPolicy
import LeapinNet
import LeapinIntegrations

@MainActor
struct AdBlockView: View {
    @ObservedObject private var engine = LeapinEngine.shared
    @EnvironmentObject private var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            VStack(spacing: 22) {
                instrumentBar
                enginePanel
                testCard

                HStack(alignment: .top, spacing: 22) {
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
        .lpConfirm("覆盖现有白名单？",
                   message: "保存会用编辑器中的 \(pendingAllowList.count) 条替换当前白名单，此操作可在提示条中撤销。",
                   isPresented: $showAllowConfirm,
                   confirmTitle: "覆盖保存") {
            applyAllowList(pendingAllowList)
        }
    }

    // MARK: Instrument bar

    private var instrumentBar: some View {
        HStack(spacing: 0) {
            metric("过滤规则 / RULES", "\(engine.adblockRuleCount)", caption: "ABP 与 hosts 规则总数")
            Rectangle().fill(LP.stroke).frame(width: 1, height: 44)
            metric("已拦截 / BLOCKED", "\(engine.stats.blocked)", caption: "本次会话累计")
            Rectangle().fill(LP.stroke).frame(width: 1, height: 44)
            metric("白名单 / ALLOW",
                   "\(engine.profile.adblock.allowList.count)",
                   caption: "优先于拦截规则")
        }
        .padding(.vertical, 2)
        .lpPanel(padding: 0)
    }

    private func metric(_ label: String, _ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            LPEyebrow(text: label)
            Text(value)
                .font(LPFont.num(26, weight: .medium))
                .foregroundStyle(LP.text)
                .lineLimit(1)
                .contentTransition(.numericText())
                .lpAnimation(LPMotion.emphasized, value: value)
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(LP.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Engine

    private var enginePanel: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "去广告引擎",
                          subtitle: engine.adblockActive ? "运行中" : "未加载",
                          icon: engine.profile.adblock.enabled ? "hand.raised" : "hand.raised.slash",
                          tint: engine.profile.adblock.enabled ? LP.danger : LP.textTertiary)
                .padding(18)

            LPDivider()

            toggleRow("启用广告与跟踪器拦截",
                      "关闭后所有域名直接放行，规则分流仍然生效",
                      isOn: Binding(
                        get: { engine.profile.adblock.enabled },
                        set: { value in
                            engine.setAdBlockEnabled(value)
                            app.showToast(value ? "去广告已开启" : "去广告已关闭", kind: value ? .success : .info)
                        }
                      ),
                      strong: true)

            LPDivider()

            toggleRow("跟踪器名单",
                      "按内置域名表拦截已知跟踪器",
                      isOn: Binding(
                        get: { engine.profile.adblock.blockTrackers },
                        set: { v in engine.updateProfile(restart: true) { $0.adblock.blockTrackers = v } }
                      ))

            LPDivider()

            toggleRow("hosts 语法",
                      "兼容 0.0.0.0 domain 形式的 hosts 名单",
                      isOn: Binding(
                        get: { engine.profile.adblock.hostsBlocking },
                        set: { v in engine.updateProfile(restart: true) { $0.adblock.hostsBlocking = v } }
                      ))

            LPDivider()

            toggleRow("元素隐藏",
                      "注入 CSS 规则隐藏页面上的广告位",
                      isOn: Binding(
                        get: { engine.profile.adblock.cosmeticFiltering },
                        set: { v in engine.updateProfile(restart: false) { $0.adblock.cosmeticFiltering = v } }
                      ))
        }
        .lpPanel(padding: 0)
    }

    private func toggleRow(_ title: String, _ detail: String, isOn: Binding<Bool>, strong: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: strong ? 13 : 12.5, weight: strong ? .semibold : .medium))
                    .foregroundStyle(LP.text)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            LPSwitch(isOn: isOn, tint: LP.accent, width: 32)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, strong ? 14 : 12)
    }

    // MARK: Probe

    private var testCard: some View {
        Card(title: "拦截测试",
             subtitle: "输入域名验证是否命中广告规则（仅按域名判定，不看路径）",
             icon: "testtube.2") {
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(probeFocused ? LP.accent : LP.textTertiary)
                    TextField("doubleclick.net", text: $probe)
                        .textFieldStyle(.plain)
                        .font(LPFont.mono(12))
                        .focused($probeFocused)
                        .onSubmit(run)
                    if !probe.isEmpty {
                        Button { probe = ""; result = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(LP.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除域名")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .lpGlass(in: Capsule(style: .continuous),
                         fallbackFill: LP.panelSolid,
                         fallbackMaterial: .thinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(probeFocused ? LP.accent.opacity(0.55) : .clear, lineWidth: 1.2)
                )

                Button("检查", action: run)
                    .buttonStyle(LPPrimaryButtonStyle())
                    .disabled(probe.isEmpty)
            }

            if let result {
                HStack(spacing: 9) {
                    Circle()
                        .fill(result.blocked ? LP.danger : LP.mint)
                        .frame(width: 6, height: 6)
                    Text(result.blocked ? "已拦截" : "放行")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LP.text)
                    if let reason = result.reason {
                        Text(reason)
                            .font(LPFont.mono(12))
                            .foregroundStyle(LP.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Button {
                        LPClipboard.copy(result.blocked ? "blocked" : "allowed")
                        app.showToast("已复制结论", kind: .info)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LP.textTertiary)
                    .accessibilityLabel("复制测试结论")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(LP.stroke, lineWidth: 1)
                )
            }
        }
    }

    // MARK: Lists

    private var blockLists: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "过滤列表",
                          subtitle: "\(engine.profile.adblock.blockLists.count) 个来源",
                          icon: "doc.text")
                .padding(18)

            LPDivider()

            if engine.profile.adblock.blockLists.isEmpty {
                Text("还没有自定义来源 · 默认使用内置 leapin-ads.txt（约 100 条）")
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(engine.profile.adblock.blockLists, id: \.self) { item in
                        HStack(spacing: 9) {
                            Image(systemName: item.hasPrefix("http") ? "link" : "doc.text")
                                .font(.system(size: 10))
                                .foregroundStyle(LP.textTertiary)
                                .frame(width: 14)
                            Text(item)
                                .font(LPFont.mono(12))
                                .foregroundStyle(LP.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button {
                                removeList(item)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(LP.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .help("移除来源")
                            .accessibilityLabel("移除来源 \(item)")
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 18)
                        LPDivider().padding(.leading, 41)
                    }
                }
            }

            LPDivider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(LP.textTertiary)
                        TextField("https://… 或本地文件路径", text: $newList)
                            .textFieldStyle(.plain)
                            .font(LPFont.mono(12))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .lpGlass(radius: 10,
                             fallbackFill: LP.panelSolid,
                             fallbackMaterial: .thinMaterial)

                    Button("添加", action: addList)
                        .buttonStyle(LPGhostButtonStyle())
                        .disabled(newList.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("支持 ABP（||domain^、@@ 例外、$third-party）与 hosts 行。名单在启动时加载，10 万条以内可秒级完成。")
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .lpPanel(padding: 0)
        .frame(maxWidth: .infinity)
    }

    private var allowList: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "白名单", subtitle: "每行一个域名，优先级最高", icon: "checkmark.shield")
                .padding(18)

            LPDivider()

            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $allowText)
                        .font(LPFont.mono(12))
                        .frame(height: 148)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .lpGlass(radius: 14,
                                 fallbackFill: LP.panelSolid,
                                 fallbackMaterial: .thinMaterial)
                    if allowText.isEmpty {
                        Text("还没有白名单。每行写一个域名，这些域名将跳过所有拦截规则。")
                            .font(.system(size: 12))
                            .foregroundStyle(LP.textTertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 15)
                            .allowsHitTesting(false)
                    }
                }

                HStack(spacing: 8) {
                    Text("\(allowLineCount) 条")
                        .font(LPFont.num(11))
                        .foregroundStyle(LP.textTertiary)
                    Spacer()
                    Button("保存白名单", action: requestSaveAllowList)
                        .buttonStyle(LPGhostButtonStyle())
                }
                Text("保存会整份替换当前白名单；空行会被忽略，可在提示条中撤销。")
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textTertiary)
            }
            .padding(18)
        }
        .lpPanel(padding: 0)
        .frame(maxWidth: .infinity)
    }

    private var allowLineCount: Int {
        allowText.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    private func addList() {
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

    private func removeList(_ item: String) {
        engine.updateProfile(restart: true) { $0.adblock.blockLists.removeAll { $0 == item } }
        app.showToast("已移除来源", kind: .info, actionTitle: "撤销") {
            engine.updateProfile(restart: true) { profile in
                if !profile.adblock.blockLists.contains(item) {
                    profile.adblock.blockLists.append(item)
                }
            }
        }
    }

    private func requestSaveAllowList() {
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
