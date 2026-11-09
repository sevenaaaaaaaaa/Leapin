import Foundation
import LeapinRuntime
import LeapinCore
import LeapinPolicy
import LeapinNet
import LeapinIntegrations
import LeapinSync

@main
struct LeapinCLI {
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
            case "http-probe":
                try await httpProbe(args)
            case "proxy":
                try systemProxy(args)
            case "profiles":
                listProfiles()
            case "device":
                try device(args)
            case "sync":
                try await sync(args)
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
        let engine = await MainActor.run { LeapinEngine() }
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
        print("Leapin 运行中：HTTP/SOCKS5 127.0.0.1:\(port)  DNS 127.0.0.1:\(dnsPort)")
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
        let host = positional(args, valueFlags: ["--profile", "--port", "--app", "--measure"]) ?? "example.com"
        let portRaw = flag("--port", in: args)
        let port: UInt16
        if let raw = portRaw {
            guard let parsed = UInt16(raw), parsed > 0 else {
                throw LeapinError.invalidConfiguration("无效端口：\(raw)")
            }
            port = parsed
        } else {
            port = 443
        }
        let meta = ConnectionMeta(host: host, port: port, sourceApp: flag("--app", in: args))
        let match = engine.explain(meta)
        print("命中规则：\(match.matchedRule?.raw ?? "无")")
        print("策略：\(match.policy)")
        for line in match.trace { print("  · \(line)") }
        let decision = engine.decide(meta)
        print("出站：\(decision.outbound.name) (\(decision.outbound.type.rawValue) \(decision.outbound.host):\(decision.outbound.port))")
        if args.contains("--diagnose") {
            printRuleDiagnostics(engine)
        }
        if args.contains("--measure") {
            let iterations: Int
            if let raw = flag("--measure", in: args), raw != "--diagnose" {
                guard let parsed = Int(raw), parsed > 0 else {
                    throw LeapinError.invalidConfiguration("无效次数：\(raw)")
                }
                iterations = parsed
            } else {
                iterations = 2000
            }
            measure(engine: engine, meta: meta, iterations: iterations)
        }
    }

    /// 打印静态诊断：永不命中的规则（重复/被遮蔽/FINAL 之后/永远不匹配）。
    static func printRuleDiagnostics(_ engine: RuleEngine) {
        let items = engine.diagnostics()
        guard !items.isEmpty else {
            print("没有永不命中的规则")
            return
        }
        print("永不命中规则：\(items.count) 条")
        for item in items {
            print("  #\(item.index + 1)  \(item.raw)")
            print("    原因：\(item.reason)")
            if let shadow = item.shadowedByIndex {
                print("    被 #\(shadow + 1) 遮蔽")
            }
        }
    }

    /// Percentile over an ascending sample array (nearest-rank).
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p / 100.0 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    static func measure(engine: RuleEngine, meta: ConnectionMeta, iterations: Int) {
        for _ in 0..<100 { _ = engine.decide(meta) }
        var samples = [Double]()
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = engine.decide(meta)
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end - start) / 1_000_000.0)
        }
        samples.sort()
        let p50 = percentile(samples, 50)
        let p95 = percentile(samples, 95)
        print("规则数：\(engine.ruleCount)  p50：\(String(format: "%.3f", p50)) ms  p95：\(String(format: "%.3f", p95)) ms（\(iterations) 次 decide，预热 100）")
    }

    static func adblock(_ args: [String]) async throws {
        let profile = try loadProfile(args)
        var paths = profile.adblock.blockLists
        let bundled = ProfileStore.shared.ensureBundledLists().appendingPathComponent("leapin-ads.txt").path
        paths.append(bundled)
        let engine = try AdBlockEngine.load(listPaths: paths, allowList: profile.adblock.allowList)
        let domain = args.first(where: { !$0.hasPrefix("-") }) ?? "doubleclick.net"
        let verdict = engine.verdict(for: domain, thirdParty: false)
        print("规则数：\(engine.ruleCount)")
        print("\(domain) → \(verdict.blocked ? "拦截" : "放行") \(verdict.reason ?? "")")
    }

    static func importProfile(_ args: [String]) async throws {
        if args.contains("--help") || args.contains("-h") {
            print("用法：leapin import <file>  （支持 Clash YAML / Surge conf / Leapin JSON / base64 订阅）")
            return
        }
        guard let path = args.first(where: { !$0.hasPrefix("-") }) else {
            throw LeapinError.invalidConfiguration("用法：leapin import <file>")
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
            print("用法：leapin export [--profile <file>] [clash|surge|json|hosts|abp|ruleset]（缺省 clash）")
            return
        }
        let profilePath = flag("--profile", in: args)
        let token = args.first { !$0.hasPrefix("-") && $0 != profilePath } ?? "clash"
        guard let format = ProfileFormat(cliName: token) else {
            throw LeapinError.invalidConfiguration("未知导出格式：\(token)（支持 clash / surge / json / hosts / abp / ruleset）")
        }
        let profile = try loadProfile(args)
        print(try ProfileStore.shared.export(profile, format: format))
    }

    static func resolveDNS(_ args: [String]) async throws {
        let profile = try loadProfile(args)
        guard let host = positional(args, valueFlags: ["--profile"]) else {
            throw LeapinError.invalidConfiguration("用法：leapin dns <host> [--trace] [--profile file]")
        }
        let resolver = DNSResolver(config: profile.dns)
        if args.contains("--trace") {
            let trace = await resolver.trace(host)
            print("host：\(trace.host)")
            print("source：\(trace.source.rawValue)")
            print("upstream：\(trace.upstream ?? "-")")
            print(String(format: "elapsedMs：%.3f", trace.elapsedMs))
            print("cacheTTL：\(trace.cacheTTL.map(String.init) ?? "-")")
            print("resolved：\(trace.resolved.isEmpty ? "-" : trace.resolved.joined(separator: ", "))")
            print("steps：")
            if trace.steps.isEmpty {
                print("  · 无")
            }
            for step in trace.steps {
                print(String(format: "  · [%@] %@ (%.3f ms)", step.stage, step.detail, step.elapsedMs))
            }
            if let error = trace.error {
                FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
                exit(1)
            }
            return
        }
        let ips = try await resolver.resolve(host)
        print(ips.joined(separator: "\n"))
    }

    /// First positional argument, skipping value-taking flags and their values.
    static func positional(_ args: [String], valueFlags: [String]) -> String? {
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if valueFlags.contains(arg) { skipNext = true; continue }
            if arg.hasPrefix("-") { continue }
            return arg
        }
        return nil
    }

    static func httpProbe(_ args: [String]) async throws {
        if args.contains("--help") || args.contains("-h") {
            print("用法：leapin http-probe <url> [--timeout ms] [--json]")
            return
        }
        let timeoutRaw = flag("--timeout", in: args)
        let timeout = timeoutRaw.flatMap(Int.init) ?? 8000
        guard let url = args.first(where: { !$0.hasPrefix("-") && $0 != timeoutRaw }) else {
            throw LeapinError.invalidConfiguration("用法：leapin http-probe <url> [--timeout ms] [--json]")
        }
        let result = await HTTPProbe.probe(url, timeoutMs: timeout)
        if args.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(result), let text = String(data: data, encoding: .utf8) {
                print(text)
            } else {
                print("{\"error\":\"encode-failed\"}")
            }
        } else {
            print("状态码：\(result.statusCode.map(String.init) ?? "-")")
            print(String(format: "耗时：%.3f ms", result.elapsedMs))
            print("远端：\(result.remoteAddress ?? "-")")
            print("TLS：\(result.tls ? "是" : "否")")
            print("HTTP 版本：\(result.httpVersion ?? "-")")
            print("重定向：\(result.redirects)")
            for (name, value) in result.headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
                print("  \(name): \(value)")
            }
            print("字节：头 \(result.headerBytes) / 体 \(result.bodyBytes)")
        }
        if let error = result.error {
            FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
            exit(1)
        }
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
            print("用法：leapin proxy status|on|off")
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

    // MARK: - Device identity & sync

    static func syncService() -> ProfileSyncService {
        let root = ProfileStore.shared.root
        let forcedFile = ProcessInfo.processInfo.environment["LEAPIN_SYNC_FILE_KEY"] == "1"
        let store: SecretStore? = forcedFile
            ? FileSecretStore(directory: root.appendingPathComponent("device", isDirectory: true))
            : nil
        return ProfileSyncService(root: root, profileStore: .shared, secretStore: store)
    }

    static func parseEndpoint(_ text: String) throws -> (host: String, port: UInt16) {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]), !parts[0].isEmpty else {
            throw LeapinError.invalidConfiguration("地址应形如 host:port，收到 " + text)
        }
        return (String(parts[0]), port)
    }

    static func device(_ args: [String]) throws {
        let service = syncService()
        let identity = try service.identity()
        if args.contains("--json") {
            let payload: [String: Any] = [
                "deviceID": identity.deviceID,
                "fingerprint": identity.fingerprint,
                "publicKey": DeviceIdentity.encodePublicKey(identity.publicKeyData),
                "name": service.deviceName,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        print("设备 ID：" + identity.deviceID)
        print("指纹：" + identity.fingerprint)
        print("名称：" + service.deviceName)
        print("公钥：" + DeviceIdentity.encodePublicKey(identity.publicKeyData))
    }

    static func sync(_ args: [String]) async throws {
        guard let sub = args.first else {
            print("用法：leapin sync status|versions|serve|pair <host:port> --code NNNNNN|pull <host:port>|apply [--version id]")
            return
        }
        let service = syncService()
        let rest = Array(args.dropFirst())
        switch sub {
        case "record":
            if let path = flag("--profile", in: rest) {
                let url = URL(fileURLWithPath: path)
                let outcome = try ProfileStore.shared.importFileDetailed(at: url)
                ProfileStore.shared.activeProfileID = outcome.profile.id
                let version = try service.recordActiveProfile()
                print("已记录版本 " + String(version.id.prefix(12)) + "（" + String(version.ruleCount) + " 条规则）")
            } else {
                let version = try service.recordActiveProfile()
                print("已记录版本 " + String(version.id.prefix(12)) + "（" + String(version.ruleCount) + " 条规则）")
            }
        case "status":
            let migrated = try service.migrateIfNeeded()
            let identity = try service.identity()
            let versions = service.versions.list()
            let active = service.versions.effectiveActiveVersion()
            if rest.contains("--json") {
                let identityJSON: [String: Any] = [
                    "deviceID": identity.deviceID,
                    "name": service.deviceName,
                    "fingerprint": identity.fingerprint,
                ]
                let payload: [String: Any] = [
                    "device": identityJSON,
                    "versions": versions.map { [
                        "id": $0.id, "name": $0.name, "ruleCount": $0.ruleCount,
                        "createdAtMs": $0.createdAtMs, "originDevice": $0.originDevice,
                    ] },
                    "effective": active ?? "",
                    "applied": service.appliedVersion ?? "",
                    "override": service.versions.overrideVersion ?? "",
                    "peers": service.peers.all().map { $0.device.deviceID },
                ]
                let data = try JSONSerialization.data(withJSONObject: payload,
                                                      options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return
            }
            if let migrated {
                print("首次迁移：已把当前配置记为版本 " + migrated.id.prefix(12))
            }
            print("设备：" + service.deviceName + "（" + identity.deviceID + "）")
            let recent = versions.prefix(3).map { String($0.id.prefix(12)) }.joined(separator: ", ")
            print("版本：" + String(versions.count) + " 个，最近 " + (recent.isEmpty ? "无" : recent))
            print("生效版本：" + (active.map { String($0.prefix(12)) } ?? "无"))
            print("已应用：" + (service.appliedVersion.map { String($0.prefix(12)) } ?? "无"))
            let peers = service.peers.all()
            if peers.isEmpty {
                print("已配对设备：无")
            } else {
                for peer in peers {
                    print("已配对：" + peer.device.name + " " + peer.device.fingerprint)
                }
            }
        case "versions":
            for version in service.versions.list() {
                let pointer = service.versions.pointers()[version.originDevice]
                let marker = pointer?.version == version.id ? "*" : " "
                let active = service.versions.effectiveActiveVersion() == version.id ? "▶" : " "
                print(marker + active + " " + String(version.id.prefix(12)) + "  " + version.name
                      + "  " + String(version.ruleCount) + " 条  " + String(version.createdAtMs))
            }
        case "serve":
            // Long-running: stdout must not sit in the file buffer, otherwise a
            // redirected log never shows the port/pairing code until exit.
            setbuf(stdout, nil)
            let port = UInt16(flag("--port", in: rest) ?? "7901") ?? 7901
            let bindLAN = rest.contains("--lan")
            let identity = try service.identity()
            let panelRoot = service.root.appendingPathComponent("sync", isDirectory: true)
            let panelEnabled = !rest.contains("--no-panel")
            let initialPanelToken = panelEnabled ? try PanelTokenStore.token(root: panelRoot) : nil
            var tokenProvider: (@Sendable () -> String?)? = nil
            if panelEnabled {
                tokenProvider = { try? PanelTokenStore.token(root: panelRoot) }
            }
            var appliedProvider: (@Sendable () -> String?)? = nil
            appliedProvider = { service.appliedVersion }
            let server = SyncServer(identity: identity, store: service.versions,
                                    peers: service.peers, port: port,
                                    bindLAN: bindLAN, deviceName: service.deviceName,
                                    panelToken: initialPanelToken,
                                    panelTokenProvider: tokenProvider,
                                    appliedVersionProvider: appliedProvider)
            let actual = try server.start()
            print("同步服务已启动：" + (bindLAN ? "0.0.0.0" : "127.0.0.1") + ":" + String(actual))
            print("配对码：" + server.pairingCode + "（5 分钟内有效，仅一次）")
            if let panelToken = initialPanelToken {
                let panelHost = bindLAN ? "<本机局域网 IP>" : "127.0.0.1"
                print("只读面板：http://" + panelHost + ":" + String(actual) + "/panel?token=" + panelToken)
                print("面板令牌：" + panelToken + "（只读；leapin sync panel --rotate 轮换）")
            }
            print("Ctrl-C 停止。")
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            var stopped = false
            source.setEventHandler {
                guard !stopped else { return }
                stopped = true
                Task {
                    server.stop()
                    exit(0)
                }
            }
            source.resume()
            while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
        case "pair":
            guard let endpointText = rest.first(where: { !$0.hasPrefix("--") }),
                  let code = flag("--code", in: rest) else {
                throw LeapinError.invalidConfiguration("用法：leapin sync pair <host:port> --code NNNNNN")
            }
            let endpoint = try parseEndpoint(endpointText)
            let client = SyncClient(identity: try service.identity(), store: service.versions,
                                    peers: service.peers, host: endpoint.host, port: endpoint.port)
            let serverDevice = try await client.pair(code: PairingCode.normalize(code))
            print("已配对：" + serverDevice.name)
            print("对方设备：" + serverDevice.deviceID)
            print("对方指纹：" + serverDevice.fingerprint + "（请与对方屏幕核对）")
        case "pull":
            guard let endpointText = rest.first(where: { !$0.hasPrefix("--") }) else {
                throw LeapinError.invalidConfiguration("用法：leapin sync pull <host:port>")
            }
            let endpoint = try parseEndpoint(endpointText)
            let client = SyncClient(identity: try service.identity(), store: service.versions,
                                    peers: service.peers, host: endpoint.host, port: endpoint.port)
            let report = try await client.syncOnce()
            print("拉取版本：" + (report.pulled.isEmpty ? "无" : report.pulled.map { String($0.prefix(12)) }.joined(separator: ", ")))
            print("指针更新：" + (report.pointersChanged.isEmpty ? "无" : report.pointersChanged.joined(separator: ", ")))
            if let active = service.versions.effectiveActiveVersion() {
                print("生效版本：" + String(active.prefix(12)))
                if service.appliedVersion != active {
                    let profile = try service.apply(versionID: active)
                    print("已应用配置：" + profile.name + "（" + String(profile.rules.count) + " 条规则）")
                }
            }
        case "peers":
            let peers = service.peers.all()
            if peers.isEmpty {
                print("尚未配对其它设备。")
            } else {
                for peer in peers {
                    print(peer.device.name + "  " + peer.device.deviceID + "  "
                          + peer.device.fingerprint + "  最近 " + String(peer.lastSeenMs))
                }
            }
        case "unpair":
            guard let target = rest.first, !target.hasPrefix("--") else {
                throw LeapinError.invalidConfiguration("用法：leapin sync unpair <deviceID|名称前缀>")
            }
            let candidates = service.peers.all().filter {
                $0.device.deviceID == target || $0.device.name == target
                    || $0.device.deviceID.hasPrefix(target)
            }
            guard let peer = candidates.first else {
                throw LeapinError.invalidConfiguration("找不到已配对设备：" + target)
            }
            guard candidates.count == 1 else {
                throw LeapinError.invalidConfiguration("匹配到多台设备，请给出更长的 deviceID 前缀")
            }
            service.peers.remove(deviceID: peer.device.deviceID)
            print("已解除配对：" + peer.device.name + "（" + peer.device.deviceID + "）")
        case "panel":
            let panelRoot = service.root.appendingPathComponent("sync", isDirectory: true)
            let rotate = rest.contains("--rotate")
            let token = rotate
                ? try PanelTokenStore.rotate(root: panelRoot)
                : try PanelTokenStore.token(root: panelRoot)
            let port = UInt16(flag("--port", in: rest) ?? "7901") ?? 7901
            let host = flag("--host", in: rest) ?? "127.0.0.1"
            let url = "http://" + host + ":" + String(port) + "/panel?token=" + token
            if rest.contains("--json") {
                let payload: [String: Any] = ["url": url, "token": token,
                                              "port": Int(port), "rotated": rotate]
                let data = try JSONSerialization.data(withJSONObject: payload,
                                                      options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return
            }
            if rotate { print("面板令牌已轮换。") }
            print("只读面板：" + url)
            print("说明：需先在同步服务里启用面板（leapin sync serve；--no-panel 关闭）。")
        case "apply":
            let target = flag("--version", in: rest) ?? service.versions.effectiveActiveVersion()
            guard let target else { throw LeapinError.invalidConfiguration("还没有任何版本") }
            let profile = try service.apply(versionID: target)
            print("已应用：" + profile.name + "（版本 " + String(target.prefix(12)) + "）")
        case "override":
            guard let target = rest.first else {
                if let current = service.versions.overrideVersion {
                    print("当前 override：" + String(current.prefix(12)))
                } else {
                    print("当前无 override；传 --clear 可清除")
                }
                return
            }
            if target == "--clear" {
                try service.versions.setOverride(nil)
                print("已清除 override")
            } else {
                try service.versions.setOverride(target)
                print("已固定到版本 " + String(target.prefix(12)))
            }
        default:
            throw LeapinError.invalidConfiguration("未知 sync 子命令：" + sub)
        }
    }

    static func printUsage() {
        print("""
        Leapin CLI

        用法：
          leapin run [--profile <file>]        启动本地代理（前台运行）
          leapin rules <host> [--port N] [--app NAME] [--profile file] [--diagnose] [--measure N]
                                              解释命中/出站；--diagnose 列出永不命中；--measure 测 p50/p95
          leapin adblock <domain>              检查域名是否被拦截
          leapin dns <host> [--trace] [--profile file]  用当前 DNS 配置解析（--trace 显示逐级过程）
          leapin http-probe <url> [--timeout ms] [--json]  直连探测 HTTP/S（不走系统代理）
          leapin import <file>                 导入 Clash/Surge/JSON/base64 订阅
          leapin export [clash|surge|json|hosts|abp|ruleset]  导出配置（缺省 clash）
          leapin export --help                 导出格式说明
          leapin proxy status|on|off            系统代理开关
          leapin profiles                      列出配置
          leapin device [--json]               显示本机设备 ID / Ed25519 指纹
          leapin sync status [--json]|versions 版本历史与生效版本
          leapin sync record [--profile file]   把当前/指定配置记为新版本
          leapin sync serve [--port N] [--lan] 启动局域网同步（默认 127.0.0.1:7901，打印配对码）
          leapin sync pair <host:port> --code NNNNNN   配对另一台设备
          leapin sync pull <host:port>         拉取并应用最新版本
          leapin sync apply [--version id]     应用指定/最新版本
          leapin sync override <id>|--clear    固定本机版本（不同步）
          leapin sync panel [--rotate] [--port N] [--host H] [--json]  只读面板链接与令牌
          leapin sync peers                    列出已配对设备
          leapin sync unpair <id|名称>          解除配对（撤销该设备签名权限）
        """)
    }
}