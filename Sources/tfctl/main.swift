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
            let text = try String(contentsOf: url, encoding: .utf8)
            if url.pathExtension.lowercased() == "json" {
                return try JSONDecoder.touchflow.decode(Profile.self, from: Data(text.utf8))
            }
            if text.contains("[Rule]") { return try ProfileImporter.surge(text, name: url.lastPathComponent) }
            return try ProfileImporter.clash(text, name: url.lastPathComponent)
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
        guard let path = args.first else { throw TouchFlowError.invalidConfiguration("用法：tfctl import <file>") }
        let profile = try ProfileStore.shared.importFile(at: URL(fileURLWithPath: path))
        print("已导入：\(profile.name)（\(profile.rules.count) 条规则，\(profile.outbounds.count) 个出站）")
        print("id: \(profile.id.uuidString)")
    }

    static func exportProfile(_ args: [String]) async throws {
        let format = args.first.flatMap { ProfileFormat(rawValue: $0) } ?? .clash
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
          tfctl import <file>                 导入 Clash/Surge/TouchFlow 配置
          tfctl export <format>               导出 clash / surge / json
          tfctl proxy status|on|off            系统代理开关
          tfctl profiles                      列出配置
        """)
    }
}
