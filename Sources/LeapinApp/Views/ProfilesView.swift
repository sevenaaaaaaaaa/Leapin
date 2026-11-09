import SwiftUI
import AppKit
import LeapinCore
import LeapinRuntime
import LeapinPolicy
import LeapinNet
import LeapinIntegrations

@MainActor
struct ProfilesView: View {
    @ObservedObject private var engine = LeapinEngine.shared
    @EnvironmentObject private var app: AppModel
    @State private var metas: [ProfileMeta] = []
    @State private var pendingDelete: ProfileMeta?
    @State private var search = ""
    @State private var activating: UUID?
    @FocusState private var searchFocused: Bool

    private var currentMeta: ProfileMeta? {
        metas.first { $0.id == engine.profile.id }
    }

    private func activate(_ meta: ProfileMeta) {
        activating = meta.id
        Task {
            await engine.activate(meta.id)
            activating = nil
            refresh()
            if engine.profile.id == meta.id {
                app.showToast("已切换到 \(meta.name)", kind: .success)
            } else {
                app.showToast("切换失败：\(engine.lastError ?? "配置无法载入")", kind: .error)
            }
        }
    }

    private var filtered: [ProfileMeta] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return metas }
        return metas.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                heroPanel
                listPanel
                importSourcesPanel
            }
            .pagePadding()
        }
        .navigationTitle("配置")
        .onAppear(perform: refresh)
        .onChange(of: engine.profile.id) { _, _ in refresh() }
        .onChange(of: app.searchFocusRequest) { _, _ in searchFocused = true }
        .lpConfirm("删除配置？",
                   message: "将同时删除该配置的本地 JSON 文件，不可恢复。",
                   isPresented: Binding(get: { pendingDelete != nil },
                                        set: { if !$0 { pendingDelete = nil } }),
                   confirmTitle: "删除") {
            if let meta = pendingDelete {
                engine.store.delete(id: meta.id)
                refresh()
                app.showToast("已删除 \(meta.name)", kind: .info)
            }
            pendingDelete = nil
        }
    }

    // MARK: Hero

    private var heroPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    LPEyebrow("当前配置 / Active profile")

                    Text(engine.profile.name)
                        .font(LPFont.display(20, weight: .semibold))
                        .foregroundStyle(LP.text)
                        .lineLimit(1)

                    HStack(spacing: 7) {
                        Text("\(engine.ruleCount) 条规则")
                            .font(LPFont.mono(12))
                            .foregroundStyle(LP.textSecondary)
                        Text("·")
                            .font(LPFont.mono(12))
                            .foregroundStyle(LP.textTertiary)
                        Text(currentMeta.map { Fmt.day($0.updatedAt) } ?? "本机配置")
                            .font(LPFont.mono(12))
                            .foregroundStyle(LP.textTertiary)
                        Circle()
                            .fill(LP.mint)
                            .frame(width: 5, height: 5)
                            .padding(.leading, 4)
                        Text("已启用")
                            .font(.system(size: 10))
                            .foregroundStyle(LP.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(engine.ruleCount) 条规则，已启用")
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button {
                        app.showImporter = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 9, weight: .bold))
                            Text("导入配置")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .buttonStyle(LPPrimaryButtonStyle())
                    .accessibilityLabel("导入配置")

                    Button {
                        app.importFromClipboardLink()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.system(size: 9, weight: .bold))
                            Text("粘贴订阅")
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .buttonStyle(LPGhostButtonStyle())
                    .help("从剪贴板读取 http(s) 订阅链接并下载导入")
                    .accessibilityLabel("粘贴订阅链接")

                    Menu {
                        Button("Clash YAML") { app.exportProfile(format: .clash) }
                        Button("Surge conf") { app.exportProfile(format: .surge) }
                        Button("Leapin JSON") { app.exportProfile(format: .json) }
                        Divider()
                        Button("Hosts 拦截表（REJECT 精确域名）") { app.exportProfile(format: .hosts) }
                        Button("ABP / uBlock 过滤列表") { app.exportProfile(format: .abp) }
                        Button("Clash rule-set（classical）") { app.exportProfile(format: .ruleSet) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 9, weight: .bold))
                            Text("导出")
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .foregroundStyle(LP.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .lpGlass(in: Capsule(style: .continuous),
                                 fallbackFill: LP.panelSolid,
                                 fallbackMaterial: .thinMaterial)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("导出为 Clash / Surge / JSON / Hosts / ABP / rule-set")
                    .accessibilityLabel("导出配置")

                    Button("打开目录") {
                        NSWorkspace.shared.open(engine.store.root)
                        app.showToast("已在访达中打开配置目录", kind: .info)
                    }
                    .buttonStyle(LPGhostButtonStyle())
                }
            }

            Text("导入会自动识别格式并转换为内部模型；策略组、规则、DNS、去广告列表都会保留。导出支持 round-trip，便于在其他工具中使用。")
                .font(.system(size: 12))
                .foregroundStyle(LP.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lpPanel(padding: 0)
        .lpAppear(0)
    }

    // MARK: Profile list

    private var listPanel: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "全部配置",
                          subtitle: "\(filtered.count) / \(metas.count) 个",
                          icon: "list.bullet.rectangle")
                .padding(18)

            LPDivider()

            HStack(spacing: 12) {
                if !metas.isEmpty {
                    LPSearchField(text: $search, placeholder: "搜索配置名", width: 240, focus: $searchFocused)
                }
                Spacer(minLength: 8)
                Text("本机存储 · 导入即启用")
                    .font(LPFont.mono(10))
                    .tracking(0.8)
                    .foregroundStyle(LP.textTertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            LPDivider()

            if metas.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noResults
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, meta in
                        profileRow(meta)
                        if index < filtered.count - 1 {
                            LPDivider().padding(.leading, 46)
                        }
                    }
                }
            }
        }
        .lpPanel(padding: 0)
        .lpAppear(0.04)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("还没有配置")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LP.textSecondary)
            Text("导入 Clash YAML、Surge conf 或之前导出的 Leapin JSON 即可开始。")
                .font(.system(size: 12))
                .foregroundStyle(LP.textTertiary)
            Button("导入配置") { app.showImporter = true }
                .buttonStyle(LPGhostButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private var noResults: some View {
        HStack(spacing: 10) {
            Text("没有匹配的配置。")
                .font(.system(size: 12))
                .foregroundStyle(LP.textTertiary)
            Button("清除搜索") { search = "" }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LP.accent)
                .accessibilityLabel("清除搜索")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private func profileRow(_ meta: ProfileMeta) -> some View {
        let active = meta.id == engine.profile.id
        return HStack(spacing: 12) {
            Image(systemName: active ? "doc.text.fill" : "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(active ? LP.mint : LP.textTertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(meta.name)
                        .font(.system(size: 12, weight: active ? .semibold : .medium))
                        .foregroundStyle(LP.text)
                        .lineLimit(1)
                    if active {
                        Badge(text: "使用中", color: LP.mint)
                    }
                }
                Text("\(meta.ruleCount) 条规则 · \(Fmt.day(meta.updatedAt))")
                    .font(LPFont.mono(10))
                    .foregroundStyle(LP.textTertiary)
            }

            Spacer(minLength: 8)

            if !active {
                Button {
                    activate(meta)
                } label: {
                    if activating == meta.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("启用")
                    }
                }
                .buttonStyle(LPGhostButtonStyle())
                .disabled(activating != nil)
                .accessibilityLabel("启用 \(meta.name)")
            }

            Button(role: .destructive) {
                pendingDelete = meta
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(LP.textTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("删除该配置")
            .accessibilityLabel("删除 \(meta.name)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu {
            Button("启用") { activate(meta) }
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([engine.store.root])
            }
            Divider()
            Button("删除…", role: .destructive) { pendingDelete = meta }
        }
    }

    // MARK: Import sources

    private var importSourcesPanel: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "导入来源",
                          subtitle: "支持的格式与本机边界",
                          icon: "square.and.arrow.down.on.square")
                .padding(18)

            LPDivider()

            sourceRow("Clash YAML",
                      "proxies · proxy-groups · rules · dns · rule-providers · proxy-providers")
            LPDivider()
            sourceRow("Surge conf",
                      "[General] · [Proxy] · [Proxy Group] · [Rule] · [Host]")
            LPDivider()
            sourceRow("Leapin JSON",
                      "本应用导出的 .json，含出站、策略组、规则、DNS 与去广告列表")
            LPDivider()
            sourceRow("订阅链接",
                      "Clash 订阅、base64 节点列表，或 ss / ssr / trojan / vmess / vless / hysteria2 URI")

            LPDivider()

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10))
                    .foregroundStyle(LP.textTertiary)
                    .padding(.top, 1)
                Text("导入在本机完成，写入 Application Support/Leapin/profiles 后立即启用；订阅只访问你粘贴的 URL，内容不会上传到其他服务器。")
                    .font(.system(size: 12))
                    .foregroundStyle(LP.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .lpPanel(padding: 0)
        .lpAppear(0.08)
    }

    private func sourceRow(_ name: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(name)
                .font(LPFont.mono(12))
                .foregroundStyle(LP.textSecondary)
                .frame(width: 130, alignment: .leading)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(LP.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func refresh() {
        metas = engine.profiles
    }
}
