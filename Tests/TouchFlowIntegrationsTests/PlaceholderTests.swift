import XCTest
import AppKit
import TouchFlowCore
@testable import TouchFlowIntegrations

final class IntegrationsTests: XCTestCase {

    // MARK: 1. Catalogue sanity

    func testCatalogIsPopulatedWithPlausibleDomains() throws {
        let catalog = AppCatalog.builtin
        XCTAssertGreaterThanOrEqual(catalog.count, 30)
        XCTAssertEqual(Set(catalog.map(\.name)).count, catalog.count, "duplicate app names")
        for app in catalog {
            XCTAssertFalse(app.name.isEmpty)
            XCTAssertEqual(app.source, "catalog")
            for domain in app.domains {
                XCTAssertFalse(domain.contains(" "), "whitespace in \(domain)")
                XCTAssertEqual(domain, domain.lowercased())
                XCTAssertFalse(domain.contains("://"), "scheme in \(domain)")
                let labels = domain.split(separator: ".")
                XCTAssertGreaterThanOrEqual(labels.count, 2, "not a domain: \(domain)")
                let tld = try XCTUnwrap(labels.last)
                XCTAssertGreaterThanOrEqual(tld.count, 2, "short TLD: \(domain)")
                XCTAssertTrue(tld.allSatisfy { $0.isLetter }, "numeric TLD: \(domain)")
            }
        }
        XCTAssertTrue(catalog.contains { $0.domains.contains("github.com") })
        XCTAssertTrue(catalog.contains { $0.domains.contains("weixin.qq.com") })
    }

    // MARK: 2. Plain-text parsing

    func testParsePlainTextMatchesCatalogAndKeepsUnknownApps() {
        let text = """
        微信 weixin.qq.com
        GitHub
        某内部工具
        """
        let apps = AppListParser.parse(text: text)
        XCTAssertEqual(apps.count, 3)

        let wechat = apps.first { $0.name == "微信" }
        XCTAssertNotNil(wechat)
        XCTAssertTrue(wechat?.domains.contains("weixin.qq.com") ?? false)
        XCTAssertEqual(wechat?.source, "user")

        let github = apps.first { $0.name == "GitHub" }
        XCTAssertNotNil(github)
        XCTAssertTrue(github?.domains.contains("github.com") ?? false)

        let unknown = apps.first { $0.name == "某内部工具" }
        XCTAssertNotNil(unknown)
        XCTAssertEqual(unknown?.domains.isEmpty, true)
        XCTAssertEqual(unknown?.source, "user")
    }

    // MARK: 3. CSV and Markdown tables

    func testParseCSVAndMarkdownTable() {
        let csv = """
        App,Domain
        淘宝,taobao.com
        抖音,douyin.com
        """
        let csvApps = AppListParser.parse(text: csv)
        XCTAssertEqual(csvApps.count, 2)
        XCTAssertTrue(csvApps.contains { $0.name == "淘宝" && $0.domains.contains("taobao.com") })
        XCTAssertTrue(csvApps.contains { $0.name == "抖音" && $0.domains.contains("douyin.com") })

        let markdown = """
        | 应用 | 域名 |
        | --- | --- |
        | 小红书 | xiaohongshu.com |
        | 知乎 | zhihu.com |
        """
        let markdownApps = AppListParser.parse(text: markdown)
        XCTAssertEqual(markdownApps.count, 2)
        XCTAssertTrue(markdownApps.contains { $0.name == "小红书" && $0.domains.contains("xiaohongshu.com") })
        XCTAssertTrue(markdownApps.contains { $0.name == "知乎" && $0.domains.contains("zhihu.com") })
    }

    // MARK: 4. JSON parsing

    func testParseJSON() throws {
        let json = """
        [
          {"name": "Telegram", "domains": ["telegram.org"]},
          "Slack",
          {"name": "某内部应用", "domains": []}
        ]
        """
        let apps = AppListParser.parse(text: json)
        XCTAssertEqual(apps.count, 3)

        let telegram = try XCTUnwrap(apps.first { $0.name == "Telegram" })
        XCTAssertTrue(telegram.domains.contains("telegram.org"))
        XCTAssertTrue(telegram.domains.contains("t.me"))

        let slack = try XCTUnwrap(apps.first { $0.name == "Slack" })
        XCTAssertTrue(slack.domains.contains("slack.com"))

        let internalApp = try XCTUnwrap(apps.first { $0.name == "某内部应用" })
        XCTAssertTrue(internalApp.domains.isEmpty)
        XCTAssertEqual(internalApp.source, "user")
    }

    // MARK: 5. Rule suggestions: dedupe, ordering, shape

    func testRuleSuggesterDeduplicatesAndSorts() {
        let apps = [
            LearnedApp(name: "淘宝", domains: ["taobao.com", "tmall.com"], source: "user"),
            LearnedApp(name: "淘宝镜像", domains: ["taobao.com"], source: "user"),
        ]
        let flows = [
            FlowEvent(phase: .opened, host: "api.taobao.com", port: 443, sourceApp: "淘宝"),
            FlowEvent(phase: .opened, host: "api.taobao.com", port: 443, sourceApp: "淘宝"),
            FlowEvent(phase: .opened, host: "securepubads.g.doubleclick.net", port: 443, sourceApp: "Safari"),
        ]
        let suggestions = RuleSuggester.suggest(apps: apps, flows: flows, catalog: AppCatalog.builtin)
        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertLessThanOrEqual(suggestions.count, 200)
        XCTAssertEqual(Set(suggestions.map(\.domain)).count, suggestions.count, "domains must be unique")

        for (index, suggestion) in suggestions.enumerated() {
            XCTAssertTrue((0.5...0.95).contains(suggestion.confidence), "confidence out of range")
            XCTAssertEqual(suggestion.rule.kind, .domainSuffix)
            XCTAssertEqual(suggestion.rule.policy, "PROXY")
            XCTAssertEqual(suggestion.rule.value, suggestion.domain)
            XCTAssertFalse(suggestion.rationale.isEmpty)
            if index > 0 {
                XCTAssertGreaterThanOrEqual(suggestions[index - 1].confidence, suggestion.confidence,
                                            "not sorted by confidence")
            }
        }
        XCTAssertTrue(suggestions.contains { $0.domain == "taobao.com" })
    }

    // MARK: 6. Flow host suffix matching against the catalogue

    func testRuleSuggesterMatchesFlowsToCatalogDomains() throws {
        let apps = [LearnedApp(name: "未知应用", domains: [], source: "user")]
        let flows = [FlowEvent(phase: .opened, host: "cdn.douyin.com", port: 443, sourceApp: nil)]
        let suggestions = RuleSuggester.suggest(apps: apps, flows: flows, catalog: AppCatalog.builtin)
        let first = try XCTUnwrap(suggestions.first)
        XCTAssertEqual(first.domain, "douyin.com")
        XCTAssertEqual(first.appName, "抖音")
        XCTAssertGreaterThanOrEqual(first.confidence, 0.9)
    }

    // MARK: 7. Privacy audit

    func testPrivacyAuditEmptyAndHits() {
        XCTAssertGreaterThanOrEqual(TrackerCatalog.domains.count, 40)

        let empty = PrivacyAudit.audit(flows: [], trackerDomains: TrackerCatalog.domains)
        XCTAssertTrue(empty.findings.isEmpty)
        XCTAssertEqual(empty.trackersBlocked, 0)
        XCTAssertEqual(empty.score, 100)

        let flows = [
            FlowEvent(phase: .opened, host: "www.google-analytics.com", port: 443, sourceApp: "Safari"),
            FlowEvent(phase: .opened, host: "securepubads.g.doubleclick.net", port: 443, sourceApp: "Safari"),
            FlowEvent(phase: .opened, host: "app.adjust.com", port: 443, sourceApp: "淘宝"),
        ]
        let report = PrivacyAudit.audit(flows: flows, trackerDomains: TrackerCatalog.domains)
        XCTAssertEqual(report.findings.count, 3)
        XCTAssertEqual(report.trackersBlocked, 3)
        XCTAssertLessThan(report.score, 100)
        XCTAssertGreaterThanOrEqual(report.score, 0)
        XCTAssertTrue(report.findings.contains {
            $0.app == "Safari" && $0.domain == "doubleclick.net" && $0.severity == 3
        })
        XCTAssertEqual(report.findings.first?.category, "广告")
        XCTAssertEqual(TrackerCatalog.category(for: "hm.baidu.com"), "分析")
        XCTAssertNil(TrackerCatalog.severity(for: "example.com"))
    }

    // MARK: 8. SystemProxy pure parsing (never mutates the system)

    func testSystemProxyParsingAndStatusDoesNotCrash() {
        let onOutput = """
        Enabled: Yes
        Server: 127.0.0.1
        Port: 7890
        Authenticated Proxy Enabled: 0
        """
        let on = SystemProxy.parseProxy(onOutput)
        XCTAssertTrue(on.enabled)
        XCTAssertEqual(on.host, "127.0.0.1")
        XCTAssertEqual(on.port, 7890)

        let off = SystemProxy.parseProxy("Enabled: No\nServer: \nPort: 0\n")
        XCTAssertFalse(off.enabled)

        let services = SystemProxy.parseServices("""
        An asterisk (*) denotes that a network service is disabled.
        Wi-Fi
        *Bluetooth PAN
        USB 10/100/1000 LAN
        """)
        XCTAssertEqual(services, ["Wi-Fi", "USB 10/100/1000 LAN"])

        let order = SystemProxy.parseServiceOrder("""
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (2) USB 10/100/1000 LAN
        (Hardware Port: USB 10/100/1000 LAN, Device: en5)
        """)
        XCTAssertEqual(order.count, 2)
        XCTAssertEqual(order.first?.service, "Wi-Fi")
        XCTAssertEqual(order.first?.device, "en0")

        // Read-only: must not throw, must not modify anything.
        let status = SystemProxy.status()
        XCTAssertFalse(status.enabled && status.port < 0)
    }

    // MARK: 9. SSH failure path

    func testSSHBinarySmoke() throws {
        // 真实可测范围：本机没有可用的远程 sshd，SSH 只做「二进制存在 + 版本可用 + 失败路径明确报错」的冒烟测试。
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: SSHSession.sshPath))
        let version = try CommandRunner.run(executable: SSHSession.sshPath, arguments: ["-V"], timeout: 10)
        XCTAssertTrue(version.succeeded)
        XCTAssertTrue(version.combined.contains("OpenSSH"), "unexpected ssh -V output: \(version.combined)")
    }

    func testSSHSessionReportsFailureWithoutCrashing() async {
        let session = SSHSession()
        do {
            try await session.connect(host: "127.0.0.1", port: 1, user: "nobody",
                                      password: "not-a-real-password", keyPath: nil,
                                      knownHosts: "accept-new")
            XCTFail("connecting to 127.0.0.1:1 must fail")
        } catch let error as TouchFlowError {
            guard case .connectionFailed = error else {
                return XCTFail("unexpected TouchFlowError: \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        let connected = await session.isConnected
        XCTAssertFalse(connected)
        await session.write("echo hi\n")
        await session.disconnect()

        // Askpass helper must not survive a failed connection.
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("touchflow-ssh-") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "askpass directories left behind: \(leftovers)")
    }

    // MARK: 10. Vision OCR on a code-rendered image

    @MainActor
    func testOCRRecognisesRenderedText() throws {
        let size = NSSize(width: 720, height: 240)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let text = "微信 weixin.qq.com" as NSString
        text.draw(at: NSPoint(x: 24, y: 90), withAttributes: [
            .font: NSFont.systemFont(ofSize: 64),
            .foregroundColor: NSColor.black,
        ])
        image.unlockFocus()

        var rect = NSRect(origin: .zero, size: size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw XCTSkip("could not rasterise the test image")
        }

        let result: OCRResult
        do {
            result = try ScreenshotOCR.recognize(cgImage: cgImage)
        } catch {
            throw XCTSkip("Vision OCR unavailable in this environment: \(error.localizedDescription)")
        }
        XCTAssertFalse(result.lines.isEmpty, "no text lines recognised")
        XCTAssertGreaterThan(result.confidence, 0)
        let squeezed = result.text.lowercased().replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(squeezed.contains("weixin") || result.text.contains("微信"),
                      "unexpected OCR output: \(result.text)")
    }
}
