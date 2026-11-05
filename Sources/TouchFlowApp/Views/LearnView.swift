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
                if apps.isEmpty && suggestions.isEmpty { howCard }
                if !apps.isEmpty { appsCard }
                if !suggestions.isEmpty { suggestionCard }
            }
            .pagePadding()
        }
        .navigationTitle("智能学习")
    }

    private var howCard: some View {
        Card(title: "工作方式", subtitle: "三步把「哪个 App 走哪条线」变成规则", icon: "wand.and.stars") {
            HStack(alignment: .top, spacing: 0) {
                step(1, "识别", "App 名 / Bundle ID / 域名，或直接从截图 OCR 出应用清单")
                arrow
                step(2, "建议", "按内置 55 个应用目录与最近连接，给出直连 / 代理 / 拦截建议")
                arrow
                step(3, "落地", "勾选建议后写入分流规则，立即生效并可随时删除")
            }
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(String(n))
                    .font(TFFont.num(10, weight: .bold))
                    .foregroundStyle(TF.accent)
                    .frame(width: 18, height: 18)
                    .background(TF.accent.opacity(0.13), in: Circle())
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TF.text)
            }
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(TF.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(TF.textTertiary.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.top, 5)
    }

    private var inputCard: some View {
        Card(title: "提交 App 列表或截图", subtitle: "自动识别应用并生成分流建议", icon: "brain") {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("方式一：粘贴应用名 / Bundle ID / 域名（每行一个，逗号分隔也可）")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $rawText)
                        .font(TFFont.mono(11))
                        .frame(height: 132)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(TF.stroke.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    HStack(spacing: 8) {
                        Button("解析列表") { parseText() }
                            .buttonStyle(TFPrimaryButtonStyle())
                            .disabled(rawText.isEmpty)
                        Button("清空") { rawText = ""; apps = []; suggestions = [] }
                            .buttonStyle(TFGhostButtonStyle())
                        Spacer()
                        Text("内置目录 \(AppCatalog.builtin.count) 个应用")
                            .font(.system(size: 10))
                            .foregroundStyle(TF.textTertiary)
                    }
                }

                Rectangle().fill(TF.stroke).frame(width: 1).padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 8) {
                    Text("方式二：拖入截图（App 列表页 / 订阅页 / 分流规则页）")
                        .font(.caption).foregroundStyle(.secondary)
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(dropped ? TF.accent.opacity(0.08) : TF.stroke.opacity(0.3))
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                            .foregroundStyle(dropped ? TF.accent : TF.strokeStrong)
                        VStack(spacing: 6) {
                            Image(systemName: busy ? "hourglass" : "photo.on.rectangle.angled")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(dropped ? TF.accent : TF.textTertiary)
                            Text(busy ? "识别中…" : "拖拽图片到此处，或点下方按钮")
                                .font(.system(size: 10.5))
                                .foregroundStyle(TF.textSecondary)
                        }
                    }
                    .frame(width: 262, height: 132)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first else { return false }
                        dropped = true
                        runOCR(url: url)
                        return true
                    }
                    Button("选择截图…") { pickImage() }
                        .buttonStyle(TFGhostButtonStyle())
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
                    Image(systemName: "app.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(TF.accent)
                    Text(learned.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TF.text)
                    if let bid = learned.bundleID {
                        Text(bid)
                            .font(TFFont.mono(9.5))
                            .foregroundStyle(TF.textTertiary)
                    }
                    Spacer(minLength: 8)
                    Text(learned.domains.prefix(3).joined(separator: ", "))
                        .font(TFFont.mono(9.5))
                        .foregroundStyle(TF.textSecondary)
                        .lineLimit(1)
                    Badge(text: learned.source, color: TF.accent)
                }
                .padding(.vertical, 2)
            }
            if suggestions.isEmpty {
                HStack {
                    Spacer()
                    Button("生成分流建议") { suggest() }
                        .buttonStyle(TFPrimaryButtonStyle())
                }
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
                        Text(suggestion.domain)
                            .font(TFFont.mono(11))
                            .foregroundStyle(TF.text)
                        Badge(text: suggestion.appName, color: TF.violet)
                        Text(suggestion.rule.kind.rawValue)
                            .font(TFFont.mono(9))
                            .foregroundStyle(TF.textTertiary)
                        Text(suggestion.rationale)
                            .font(.system(size: 10))
                            .foregroundStyle(TF.textTertiary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(Int(suggestion.confidence * 100))%")
                            .font(TFFont.num(10, weight: .semibold))
                            .foregroundStyle(TF.mint)
                    }
                }
                .toggleStyle(.checkbox)
            }
            HStack(spacing: 8) {
                Text("已选 \(selected.count) 条")
                    .font(.system(size: 10.5))
                    .foregroundStyle(TF.textTertiary)
                Spacer()
                Button("全选") { selected = Set(suggestions.map(\.id)) }
                    .buttonStyle(TFGhostButtonStyle())
                Button("应用所选规则") { apply() }
                    .buttonStyle(TFPrimaryButtonStyle())
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
