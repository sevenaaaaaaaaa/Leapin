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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "配置管理", subtitle: "Clash YAML / Surge conf / TouchFlow JSON", icon: "doc.on.doc") {
                    HStack(spacing: 8) {
                        Button { app.showImporter = true } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "square.and.arrow.down").font(.system(size: 9, weight: .bold))
                                Text("导入配置").font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .buttonStyle(TFPrimaryButtonStyle())

                        Menu {
                            Button("Clash YAML") { app.exportProfile(format: .clash) }
                            Button("Surge conf") { app.exportProfile(format: .surge) }
                            Button("TouchFlow JSON") { app.exportProfile(format: .json) }
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

                Card(title: "全部配置", subtitle: "\(metas.count) 个", icon: "list.bullet.rectangle") {
                    if metas.isEmpty {
                        EmptyHint(icon: "doc", text: "还没有配置").frame(height: 120)
                    } else {
                        ForEach(metas) { meta in
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
                                    Button("启用") {
                                        Task {
                                            await engine.activate(meta.id)
                                            refresh()
                                        }
                                    }
                                    .buttonStyle(TFGhostButtonStyle())
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
                            }
                            .padding(.vertical, 6)
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
        .alert("删除配置？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let meta = pendingDelete {
                    engine.store.delete(id: meta.id)
                    refresh()
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("将同时删除该配置的本地 JSON 文件，不可恢复。")
        }
    }

    private func refresh() {
        metas = engine.profiles
    }
}
