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
            VStack(spacing: 22) {
                inputCard
                if apps.isEmpty && suggestions.isEmpty { howCard }
                if !apps.isEmpty { appsCard }
                if !suggestions.isEmpty { suggestionCard }
            }
            .pagePadding()
        }
        .navigationTitle("智能学习")
    }

    // MARK: Input

    private var inputCard: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "提交 App 列表或截图",
                          subtitle: "自动识别应用并生成分流建议",
                          icon: "brain")
                .padding(18)

            TFDivider()

            HStack(alignment: .top, spacing: 0) {
                // 方式一：文本
                VStack(alignment: .leading, spacing: 10) {
                    TFEyebrow(text: "方式一 / 粘贴文本")
                    Text("应用名、Bundle ID 或域名，每行一个；逗号分隔也可以。")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $rawText)
                            .font(TFFont.mono(12))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                        if rawText.isEmpty {
                            Text("例如：\nSpotify\ncom.spotify.client\napi.spotify.com")
                                .font(TFFont.mono(12))
                                .foregroundStyle(TF.textTertiary.opacity(0.75))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(height: 150)
                    .background(TF.panelSolid)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(TF.stroke, lineWidth: 1)
                    )

                    HStack(spacing: 8) {
                        if rawText.isEmpty {
                            Button("解析列表") { parseText() }
                                .buttonStyle(TFGhostButtonStyle())
                                .disabled(true)
                        } else {
                            Button("解析列表") { parseText() }
                                .buttonStyle(TFPrimaryButtonStyle())
                        }
                        Button("清空") { rawText = ""; apps = []; suggestions = [] }
                            .buttonStyle(TFGhostButtonStyle())
                        Spacer(minLength: 8)
                        Text("内置目录 \(AppCatalog.builtin.count) 个应用")
                            .font(.system(size: 12))
                            .foregroundStyle(TF.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)

                Rectangle()
                    .fill(TF.stroke)
                    .frame(width: 1)
                    .padding(.vertical, 18)

                // 方式二：截图 OCR
                VStack(alignment: .leading, spacing: 10) {
                    TFEyebrow(text: "方式二 / 截图 OCR")
                    Text("App 列表页、订阅页或分流规则页的截图都可以。")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(dropped ? TF.stroke.opacity(0.35) : Color.clear)
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(TF.stroke,
                                          style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        VStack(spacing: 7) {
                            Image(systemName: busy ? "hourglass" : "photo.on.rectangle.angled")
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(busy ? TF.amber : TF.textTertiary)
                            Text(busy ? "识别中…" : "拖入截图")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(TF.textSecondary)
                            Text("PNG / JPEG / HEIC / TIFF")
                                .font(.system(size: 12))
                                .foregroundStyle(TF.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(dropped ? TF.accent : Color.clear, lineWidth: 1.5)
                    )
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first else { return false }
                        dropped = true
                        runOCR(url: url)
                        return true
                    } isTargeted: { inside in
                        dropped = inside
                    }
                    .accessibilityLabel("拖入截图以识别应用列表")
                    .accessibilityHint("也可以使用下方的选择截图按钮")

                    HStack(spacing: 8) {
                        Button("选择截图…") { pickImage() }
                            .buttonStyle(TFGhostButtonStyle())
                        Spacer(minLength: 8)
                        if !ocrText.isEmpty {
                            Text("\(ocrText.count) 字")
                                .font(TFFont.num(11))
                                .foregroundStyle(TF.textTertiary)
                        }
                    }

                    if !ocrText.isEmpty {
                        Text(ocrText.prefix(120))
                            .font(TFFont.mono(10))
                            .foregroundStyle(TF.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
        }
        .tfPanel(padding: 0)
    }

    // MARK: How it works

    private var howCard: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "工作方式",
                          subtitle: "三步把「哪个 App 走哪条线」变成规则",
                          icon: "wand.and.stars")
                .padding(18)

            TFDivider()

            HStack(alignment: .top, spacing: 0) {
                step("01", "识别", "App 名 / Bundle ID / 域名，或直接从截图 OCR 出应用清单")
                stepDivider
                step("02", "建议", "按内置 \(AppCatalog.builtin.count) 个应用目录与最近连接，给出直连 / 代理 / 拦截建议")
                stepDivider
                step("03", "落地", "勾选建议后写入分流规则，立即生效并可随时删除")
            }
            .padding(18)
        }
        .tfPanel(padding: 0)
    }

    private func step(_ index: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(index)
                .font(TFFont.mono(12, weight: .medium))
                .foregroundStyle(TF.textTertiary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TF.text)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(TF.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stepDivider: some View {
        Rectangle()
            .fill(TF.stroke)
            .frame(width: 1, height: 48)
            .padding(.horizontal, 16)
    }

    // MARK: Identified apps

    private var appsCard: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "已识别应用",
                          subtitle: "\(apps.count) 个",
                          icon: "app.badge.checkmark")
                .padding(18)

            TFDivider()

            VStack(spacing: 0) {
                ForEach(apps) { learned in
                    HStack(spacing: 10) {
                        Image(systemName: "app.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(TF.textTertiary)
                            .frame(width: 14)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(learned.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(TF.text)
                            if let bid = learned.bundleID {
                                Text(bid)
                                    .font(TFFont.mono(10))
                                    .foregroundStyle(TF.textTertiary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 10)

                        Text(learned.domains.prefix(3).joined(separator: ", "))
                            .font(TFFont.mono(10))
                            .foregroundStyle(TF.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Badge(text: learned.source, color: TF.textSecondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    TFDivider()
                }
            }

            if suggestions.isEmpty {
                HStack {
                    Text("名单没问题就可以生成建议了。")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.textTertiary)
                    Spacer()
                    Button("生成分流建议") { suggest() }
                        .buttonStyle(TFGhostButtonStyle())
                }
                .padding(18)
            }
        }
        .tfPanel(padding: 0)
    }

    // MARK: Suggestions

    private var suggestionCard: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "分流建议",
                          subtitle: "勾选后写入当前配置",
                          icon: "checklist")
                .padding(18)

            TFDivider()

            VStack(spacing: 0) {
                ForEach(suggestions) { suggestion in
                    Toggle(isOn: Binding(
                        get: { selected.contains(suggestion.id) },
                        set: { on in
                            if on { selected.insert(suggestion.id) } else { selected.remove(suggestion.id) }
                        }
                    )) {
                        HStack(spacing: 9) {
                            Text(suggestion.domain)
                                .font(TFFont.mono(12))
                                .foregroundStyle(TF.text)
                            Badge(text: suggestion.appName, color: TF.textSecondary)
                            Text(suggestion.rule.kind.rawValue)
                                .font(TFFont.mono(10))
                                .foregroundStyle(TF.textTertiary)
                            Text(suggestion.rationale)
                                .font(.system(size: 12))
                                .foregroundStyle(TF.textTertiary)
                                .lineLimit(1)
                            Spacer(minLength: 10)
                            Text("\(Int(suggestion.confidence * 100))%")
                                .font(TFFont.num(11, weight: .medium))
                                .foregroundStyle(TF.textSecondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .tint(TF.textSecondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .accessibilityLabel("\(suggestion.appName) \(suggestion.domain)，\(suggestion.rule.kind.rawValue)，置信度 \(Int(suggestion.confidence * 100))%")
                    TFDivider()
                }
            }

            HStack(spacing: 10) {
                Text("已选 \(selected.count) 条")
                    .font(TFFont.num(11))
                    .foregroundStyle(TF.textTertiary)
                Spacer(minLength: 8)
                Button("全选") { selected = Set(suggestions.map(\.id)) }
                    .buttonStyle(TFGhostButtonStyle())
                Button("应用所选规则") { apply() }
                    .buttonStyle(TFPrimaryButtonStyle())
                    .disabled(selected.isEmpty)
            }
            .padding(18)
        }
        .tfPanel(padding: 0)
    }

    // MARK: Actions

    private func parseText() {
        apps = AppListParser.parse(text: rawText)
        if apps.isEmpty {
            app.showToast("没有识别出应用，请检查格式（每行一个应用名 / Bundle ID / 域名）", kind: .warning)
        } else {
            app.showToast("识别到 \(apps.count) 个应用", kind: .success)
        }
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
                if apps.isEmpty {
                    app.showToast("截图里没有识别到应用名，试试更清晰的列表页", kind: .warning)
                } else {
                    app.showToast("OCR 识别到 \(apps.count) 个应用", kind: .success)
                }
            } catch {
                app.showToast("识别失败：\(error.localizedDescription)", kind: .error)
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
        if n == 0 {
            app.showToast("这些规则都已存在，未新增", kind: .warning)
        } else {
            app.showToast("已添加 \(n) 条规则", kind: .success, actionTitle: "查看规则") { app.go(to: .rules) }
        }
        suggestions.removeAll()
        selected.removeAll()
    }
}
