import SwiftUI
import AppKit
import TouchFlowCore
import TouchFlowRuntime
import TouchFlowPolicy
import TouchFlowNet
import TouchFlowIntegrations

@MainActor
struct ProfilesView: View {
    @ObservedObject private var engine = TouchFlowEngine.shared
    @EnvironmentObject private var app: AppModel
    @State private var metas: [ProfileMeta] = []
    @State private var pendingDelete: ProfileMeta?
    @State private var search = ""
    @State private var activating: UUID?
    @FocusState private var searchFocused: Bool

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
            VStack(spacing: 16) {
                Card(title: "配置管理", subtitle: "导入 Clash / Surge / JSON；导出还可生成 Hosts、ABP、rule-set", icon: "doc.on.doc") {
                    HStack(spacing: 8) {
                        Button { app.showImporter = true } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "square.and.arrow.down").font(.system(size: 9, weight: .bold))
                                Text("导入配置").font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .buttonStyle(TFPrimaryButtonStyle())

                        Button {
                            app.importFromClipboardLink()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "link").font(.system(size: 9, weight: .bold))
                                Text("粘贴订阅链接").font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(TF.text)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(TF.stroke.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("从剪贴板读取 http(s) 订阅链接并下载导入")

                        Menu {
                            Button("Clash YAML") { app.exportProfile(format: .clash) }
                            Button("Surge conf") { app.exportProfile(format: .surge) }
                            Button("TouchFlow JSON") { app.exportProfile(format: .json) }
                            Divider()
                            Button("Hosts 拦截表（REJECT 精确域名）") { app.exportProfile(format: .hosts) }
                            Button("ABP / uBlock 过滤列表") { app.exportProfile(format: .abp) }
                            Button("Clash rule-set（classical）") { app.exportProfile(format: .ruleSet) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up").font(.system(size: 9, weight: .bold))
                                Text("导出").font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(TF.text)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(TF.stroke.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()

                        Button("打开目录") {
                            NSWorkspace.shared.open(engine.store.root)
                            app.showToast("已在访达中打开配置目录", kind: .info)
                        }
                        .buttonStyle(TFGhostButtonStyle())

                        Spacer()
                        HStack(spacing: 5) {
                            Circle().fill(TF.mint).frame(width: 5, height: 5)
                            Text("当前：\(engine.profile.name)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(TF.textSecondary)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(TF.stroke.opacity(0.35), in: Capsule())
                    }
                    Text("导入会自动识别格式并转换为内部模型；策略组、规则、DNS、去广告列表都会保留。导出支持 round-trip，便于在其他工具中使用。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                Card(title: "全部配置", subtitle: "\(filtered.count) / \(metas.count) 个", icon: "list.bullet.rectangle") {
                    if !metas.isEmpty {
                        TFSearchField(text: $search, placeholder: "搜索配置名", width: 240, focus: $searchFocused)
                            .padding(.bottom, 4)
                    }
                    if metas.isEmpty {
                        TFEmptyState(icon: "doc.badge.plus",
                                     title: "还没有配置",
                                     message: "导入 Clash YAML、Surge conf 或之前导出的 TouchFlow JSON 即可开始。",
                                     actionTitle: "导入配置",
                                     action: { app.showImporter = true })
                            .frame(height: 210)
                    } else if filtered.isEmpty {
                        TFEmptyState(icon: "magnifyingglass",
                                     title: "没有匹配的配置",
                                     message: "换个关键词试试。",
                                     actionTitle: "清除搜索",
                                     action: { search = "" })
                            .frame(height: 150)
                    } else {
                        ForEach(filtered) { meta in
                            HStack(spacing: 11) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(meta.id == engine.profile.id ? TF.accent.opacity(0.15) : TF.stroke.opacity(0.45))
                                    Image(systemName: meta.id == engine.profile.id ? "checkmark" : "doc.text")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(meta.id == engine.profile.id ? TF.accent : TF.textTertiary)
                                }
                                .frame(width: 26, height: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(meta.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(TF.text)
                                    Text("\(meta.ruleCount) 条规则 · \(Fmt.day(meta.updatedAt))")
                                        .font(TFFont.mono(9.5))
                                        .foregroundStyle(TF.textTertiary)
                                }
                                Spacer(minLength: 8)
                                if meta.id != engine.profile.id {
                                    Button {
                                        activate(meta)
                                    } label: {
                                        if activating == meta.id {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Text("启用")
                                        }
                                    }
                                    .buttonStyle(TFGhostButtonStyle())
                                    .disabled(activating != nil)
                                } else {
                                    Badge(text: "使用中", color: TF.mint)
                                }
                                Button(role: .destructive) {
                                    pendingDelete = meta
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundStyle(TF.textTertiary)
                                }
                                .buttonStyle(.plain)
                                .help("删除该配置")
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("启用") { activate(meta) }
                                Button("在访达中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([engine.store.root])
                                }
                                Divider()
                                Button("删除…", role: .destructive) { pendingDelete = meta }
                            }
                            TFDivider().opacity(0.5)
                        }
                    }
                }
            }
            .pagePadding()
        }
        .navigationTitle("配置")
        .onAppear(perform: refresh)
        .onChange(of: engine.profile.id) { _, _ in refresh() }
        .onChange(of: app.searchFocusRequest) { _, _ in searchFocused = true }
        .tfConfirm("删除配置？",
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

    private func refresh() {
        metas = engine.profiles
    }
}
