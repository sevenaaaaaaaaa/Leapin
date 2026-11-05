import SwiftUI
import UniformTypeIdentifiers
import TouchFlowCore
import TouchFlowIntegrations
import TouchFlowPolicy
import TouchFlowNet
import TouchFlowRuntime

@MainActor
struct LearnView: View {
    @ObservedObject private var engine = TouchFlowEngine.shared
    @EnvironmentObject private var app: AppModel
    @State private var rawText = ""
    @State private var apps: [LearnedApp] = []
    @State private var ocrText = ""
    @State private var suggestions: [RuleSuggestion] = []
    @State private var selected: Set<String> = []
    @State private var dropped = false
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                inputCard
                if !apps.isEmpty { appsCard }
                if !suggestions.isEmpty { suggestionCard }
            }
            .pagePadding()
        }
        .navigationTitle("智能学习")
    }

    private var inputCard: some View {
        Card(title: "提交 App 列表或截图", subtitle: "自动识别应用并生成分流建议", icon: "brain") {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("方式一：粘贴应用名 / Bundle ID / 域名（每行一个，逗号分隔也可）")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $rawText)
                        .font(.callout.monospaced())
                        .frame(height: 130)
                        .scrollContentBackground(.hidden)
                        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("解析列表") { parseText() }.disabled(rawText.isEmpty)
                        Button("清空") { rawText = ""; apps = []; suggestions = [] }
                        Spacer()
                        Text("内置目录 \(AppCatalog.builtin.count) 个应用").font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("方式二：拖入截图（App 列表页 / 订阅页 / 分流规则页）")
                        .font(.caption).foregroundStyle(.secondary)
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                            .foregroundStyle(dropped ? Color.accentColor : Color.secondary.opacity(0.5))
                        VStack(spacing: 6) {
                            Image(systemName: busy ? "hourglass" : "photo.on.rectangle.angled")
                                .font(.system(size: 24)).foregroundStyle(.secondary)
                            Text(busy ? "识别中…" : "拖拽图片到此处，或点下方按钮")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 260, height: 130)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first else { return false }
                        dropped = true
                        runOCR(url: url)
                        return true
                    }
                    Button("选择截图…") { pickImage() }
                    if !ocrText.isEmpty {
                        Text(ocrText.prefix(120)).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(width: 280)
            }
        }
    }

    private var appsCard: some View {
        Card(title: "已识别应用", subtitle: "\(apps.count) 个", icon: "app.badge.checkmark") {
            ForEach(apps) { learned in
                HStack(spacing: 8) {
                    Image(systemName: "app.fill").foregroundStyle(.secondary)
                    Text(learned.name).font(.callout)
                    if let bid = learned.bundleID {
                        Text(bid).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(learned.domains.prefix(3).joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Badge(text: learned.source, color: .blue)
                }
                .padding(.vertical, 2)
            }
            if suggestions.isEmpty {
                Button("生成分流建议") { suggest() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var suggestionCard: some View {
        Card(title: "分流建议", subtitle: "勾选后写入当前配置", icon: "checklist") {
            ForEach(suggestions) { suggestion in
                Toggle(isOn: Binding(
                    get: { selected.contains(suggestion.id) },
                    set: { on in
                        if on { selected.insert(suggestion.id) } else { selected.remove(suggestion.id) }
                    }
                )) {
                    HStack(spacing: 8) {
                        Text(suggestion.domain).font(.callout.monospaced())
                        Badge(text: suggestion.appName, color: .blue)
                        Text(suggestion.rule.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                        Text(suggestion.rationale).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer()
                        Text("\(Int(suggestion.confidence * 100))%")
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Text("已选 \(selected.count) 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("全选") { selected = Set(suggestions.map(\.id)) }
                Button("应用所选规则") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
        }
    }

    private func parseText() {
        apps = AppListParser.parse(text: rawText)
        if apps.isEmpty { app.toast = "没有识别出应用，请检查格式" }
        suggest()
    }

    private func runOCR(url: URL) {
        busy = true
        Task {
            do {
                let result = try ScreenshotOCR.recognize(imageURL: url)
                ocrText = result.text
                rawText = result.text
                apps = AppListParser.parse(text: result.text)
                suggest()
                if apps.isEmpty { app.toast = "截图里没有识别到应用名" }
            } catch {
                app.toast = "识别失败：\(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .image]
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { runOCR(url: url) }
    }

    private func suggest() {
        suggestions = RuleSuggester.suggest(apps: apps, flows: engine.flows, catalog: AppCatalog.builtin)
        selected = Set(suggestions.map(\.id))
    }

    private func apply() {
        let rules = suggestions.filter { selected.contains($0.id) }.map(\.rule)
        let n = engine.addRules(rules)
        app.toast = "已添加 \(n) 条规则"
        suggestions.removeAll()
        selected.removeAll()
    }
}
