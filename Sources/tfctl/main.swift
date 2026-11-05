import Foundation
import TouchFlowRuntime
import TouchFlowCore
import TouchFlowPolicy
import TouchFlowNet
import TouchFlowIntegrations

@main
struct TFCTL {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            exit(0)
        }
        args.removeFirst()
        do {
            switch command {
            case "run", "serve":
                try await run(args)
            case "rules":
                try await rules(args)
            case "adblock":
                try await adblock(args)
            case "import":
                try await importProfile(args)
            case "export":
                try await exportProfile(args)
            case "dns":
                try await resolveDNS(args)
            case "proxy":
                try systemProxy(args)
            case "profiles":
                listProfiles()
            case "help", "--help", "-h":
                printUsage()
            default:
                FileHandle.standardError.write(Data("未知命令：\(command)\n".utf8))
                printUsage()
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func flag(_ name: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    static func loadProfile(_ args: [String]) throws -> Profile {
        if let path = flag("--profile", in: args) {
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            let text = String(decoding: data, as: UTF8.self)
            return try ProfileImporter.importText(text,
                                                  name: url.deletingPathExtension().lastPathComponent,
                                                  pathExtension: url.pathExtension).profile
        }
        return ProfileStore.shared.activeProfile()
    }

    static func run(_ args: [String]) async throws {
        let profile = try loadProfile(args)
        let engine = await MainActor.run { TouchFlowEngine() }
        if flag("--profile", in: args) != nil {
            await MainActor.run { engine.applyProfile(profile) }
        }
        await engine.start()
        let state = await engine.state
        if case .failed(let message) = state {
            FileHandle.standardError.write(Data("启动失败：\(message)\n".utf8))
            exit(1)
        }
        let port = await engine.profile.general.mixedPort
        let dnsPort = await engine.profile.dns.listenPort
        print("TouchFlow 运行中：HTTP/SOCKS5 127.0.0.1:\(port)  DNS 127.0.0.1:\(dnsPort)")
        print("Ctrl-C 停止。")

        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        var stopped = false
        source.setEventHandler {
            guard !stopped else { return }
            stopped = true
            Task {
                await engine.stop()
                exit(0)
            }
        }
        source.resume()
        while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
    }

    static func rules(_ args: [String]) async throws {
        let profile = try loadProfile(args)
        let sets = await RuleSetLoader.load(sources: profile.rules.filter { $0.kind == .ruleSet }.map { $0.value },
                                            cacheDirectory: ProfileStore.shared.cacheDirectory)
        let engine = RuleEngine(profile: profile, ruleSets: sets)
        let host = args.first(where: { !$0.hasPrefix("-") }) ?? "example.com"
        let match = engine.explain(ConnectionMeta(host: host, port: 443))
        print("命中规则：\(match.matchedRule?.raw ?? "无")")
        print("策略：\(match.policy)")
        for line in match.trace { print("  · \(line)") }
        let decision = engine.decide(ConnectionMeta(host: host, port: 443))
        print("出站：\(decision.outbound.name) (\(decision.outbound.type.rawValue) \(decision.outbound.host):\(decision.outbound.port))")
    }

    static func adblock(_ args: [String]) async throws {
        let profile = try loadProfile(args)
        var paths = profile.adblock.blockLists
        let bundled = ProfileStore.shared.ensureBundledLists().appendingPathComponent("touchflow-ads.txt").path
        paths.append(bundled)
        let engine = try AdBlockEngine.load(listPaths: paths, allowList: profile.adblock.allowList)
        let domain = args.first(where: { !$0.hasPrefix("-") }) ?? "doubleclick.net"
        let verdict = engine.verdict(for: domain, thirdParty: false)
        print("规则数：\(engine.ruleCount)")
        print("\(domain) → \(verdict.blocked ? "拦截" : "放行") \(verdict.reason ?? "")")
    }

    static func importProfile(_ args: [String]) async throws {
        if args.contains("--help") || args.contains("-h") {
            print("用法：tfctl import <file>  （支持 Clash YAML / Surge conf / TouchFlow JSON / base64 订阅）")
            return
        }
        guard let path = args.first(where: { !$0.hasPrefix("-") }) else {
            throw TouchFlowError.invalidConfiguration("用法：tfctl import <file>")
        }
        let outcome = try ProfileStore.shared.importFileDetailed(at: URL(fileURLWithPath: path))
        print("已导入：\(outcome.profile.name)")
        print(outcome.report.summary)
        print("id: \(outcome.profile.id.uuidString)")
        for issue in outcome.report.issues.prefix(10) {
            print("  · \(issue.display)")
        }
        if outcome.report.issues.count > 10 {
            print("  … 其余 \(outcome.report.issues.count - 10) 条诊断请在应用内查看")
        }
    }

    static func exportProfile(_ args: [String]) async throws {
        if args.contains("--help") || args.contains("-h") {
            print("用法：tfctl export [--profile <file>] [clash|surge|json|hosts|abp|ruleset]（缺省 clash）")
            return
        }
        let profilePath = flag("--profile", in: args)
        let token = args.first { !$0.hasPrefix("-") && $0 != profilePath } ?? "clash"
        guard let format = ProfileFormat(cliName: token) else {
            throw TouchFlowError.invalidConfiguration("未知导出格式：\(token)（支持 clash / surge / json / hosts / abp / ruleset）")
        }
        let profile = try loadProfile(args)
        print(try ProfileStore.shared.export(profile, format: format))
    }

    static func resolveDNS(_ args: [String]) async throws {
        guard let host = args.first else { throw TouchFlowError.invalidConfiguration("用法：tfctl dns <host>") }
        let profile = try loadProfile(args)
        let resolver = DNSResolver(config: profile.dns)
        let ips = try await resolver.resolve(host)
        print(ips.joined(separator: "\n"))
    }

    static func systemProxy(_ args: [String]) throws {
        if args.contains("status") {
            let s = SystemProxy.status()
            print(s.enabled ? "系统代理：开启 \(s.host):\(s.port)" : "系统代理：关闭")
        } else if args.contains("on") {
            let profile = ProfileStore.shared.activeProfile()
            try SystemProxy.enable(host: "127.0.0.1", port: Int(profile.general.httpPort), socksPort: Int(profile.general.socksPort))
            print("系统代理已开启")
        } else if args.contains("off") {
            try SystemProxy.disable()
            print("系统代理已关闭")
        } else {
            print("用法：tfctl proxy status|on|off")
        }
    }

    static func listProfiles() {
        let metas = ProfileStore.shared.list()
        if metas.isEmpty { print("暂无配置") }
        for meta in metas {
            let active = ProfileStore.shared.activeProfileID == meta.id ? "*" : " "
            print("\(active) \(meta.name)  \(meta.ruleCount) 条规则  \(meta.id.uuidString)")
        }
    }

    static func printUsage() {
        print("""
        TouchFlow CLI

        用法：
          tfctl run [--profile <file>]        启动本地代理（前台运行）
          tfctl rules <host> [--profile file] 解释某个域名命中哪条规则
          tfctl adblock <domain>              检查域名是否被拦截
          tfctl dns <host> [--profile file]   用当前 DNS 配置解析
          tfctl import <file>                 导入 Clash/Surge/JSON/base64 订阅
          tfctl export [clash|surge|json|hosts|abp|ruleset]  导出配置（缺省 clash）
          tfctl export --help                 导出格式说明
          tfctl proxy status|on|off            系统代理开关
          tfctl profiles                      列出配置
        """)
    }
}
