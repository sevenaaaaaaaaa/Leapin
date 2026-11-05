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
                    HStack(spacing: 10) {
                        Button { app.showImporter = true } label: { Label("导入配置", systemImage: "square.and.arrow.down") }
                            .buttonStyle(.borderedProminent)
                        Menu {
                            Button("Clash YAML") { app.exportProfile(format: .clash) }
                            Button("Surge conf") { app.exportProfile(format: .surge) }
                            Button("TouchFlow JSON") { app.exportProfile(format: .json) }
                        } label: { Label("导出当前配置", systemImage: "square.and.arrow.up") }
                        Button {
                            NSWorkspace.shared.open(engine.store.root)
                        } label: { Label("打开配置目录", systemImage: "folder") }
                        Spacer()
                        Text("当前：\(engine.profile.name)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("导入会自动识别格式并转换为内部模型；策略组、规则、DNS、去广告列表都会保留。导出支持 round-trip，便于在其他工具中使用。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                Card(title: "全部配置", subtitle: "\(metas.count) 个", icon: "list.bullet.rectangle") {
                    if metas.isEmpty {
                        EmptyHint(icon: "doc", text: "还没有配置").frame(height: 120)
                    } else {
                        ForEach(metas) { meta in
                            HStack(spacing: 10) {
                                Image(systemName: meta.id == engine.profile.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(meta.id == engine.profile.id ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(meta.name).font(.callout.weight(.medium))
                                    Text("\(meta.ruleCount) 条规则 · \(Fmt.day(meta.updatedAt))").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if meta.id != engine.profile.id {
                                    Button("启用") {
                                        Task {
                                            await engine.activate(meta.id)
                                            refresh()
                                        }
                                    }
                                    .buttonStyle(.bordered).controlSize(.small)
                                } else {
                                    Badge(text: "使用中", color: .accentColor)
                                }
                                Button(role: .destructive) {
                                    pendingDelete = meta
                                } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 4)
                            Divider().opacity(0.4)
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
