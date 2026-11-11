import Foundation
import Combine
import Darwin
import LeapinCore

public enum KernelExecutable {
    public static func mihomo() -> URL? {
        let override = ProcessInfo.processInfo.environment["LEAPIN_MIHOMO_PATH"]
        let paths: [String?] = [override, UserDefaults.standard.string(forKey: "leapin.mihomo.path"), "/opt/homebrew/bin/mihomo", "/usr/local/bin/mihomo",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/mihomo").path]
        return paths.compactMap { $0 }.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    public static func version(at executable: URL) async throws -> String {
        try await Task.detached {
            let output = try CommandRunner.runChecked(executable: executable.path, arguments: ["-v"], timeout: 5)
            return Redactor.redact(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }
}

/// Preserves the source's routing and protocol fields. Only host-owned listeners,
/// Listener ownership is retained; source DNS policy runs inside the kernel.
public enum MihomoConfiguration {
    public static let ownedKeys: Set<String> = [
        "mixed-port", "port", "socks-port", "redir-port", "tproxy-port", "allow-lan", "bind-address",
        "external-controller", "external-controller-tls", "external-controller-unix", "external-controller-pipe",
        "external-ui", "external-ui-url", "external-ui-name", "secret", "authentication", "skip-auth-prefixes",
        "listeners", "tunnels", "tun", "dns", "log-level", "profile", "interface-name", "routing-mark",
    ]

    public static func managed(_ source: String, proxyPort: UInt16, controllerPort: UInt16, secret: String, tun: Bool = false, tunDevice: String = "utun198") throws -> String {
        // The parser fails loudly on unsupported YAML, rather than dropping fields.
        let root = try MiniYAML.parse(source)
        guard root.map != nil, tunDevice.range(of: #"^utun[0-9]{1,5}$"#, options: .regularExpression) != nil, proxyPort > 0, controllerPort > 0, proxyPort != controllerPort else {
            throw LeapinError.invalidConfiguration("Mihomo 配置需要 YAML 映射与两个不同的本地端口")
        }
        var lines: [String] = []
        var keep = true
        var input = source
        if input.hasPrefix("\u{FEFF}") { input.removeFirst() }
        for line in input.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." { continue }
            if !line.hasPrefix(" "), !line.hasPrefix("\t"), !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                guard let colon = line.firstIndex(of: ":") else {
                    throw LeapinError.invalidConfiguration("无法识别 YAML 顶层字段")
                }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                keep = !ownedKeys.contains(key)
            }
            if keep { lines.append(line) }
        }
        let safeSecret = String(decoding: try JSONEncoder().encode(secret), as: UTF8.self)
        lines += ["mixed-port: \(proxyPort)", "port: 0", "socks-port: 0", "redir-port: 0", "tproxy-port: 0",
                  "allow-lan: false", "bind-address: 127.0.0.1", "listeners: []",
                  "tun: \(tun ? Self.tunSettings.replacingOccurrences(of: "enable: true", with: "enable: true, device: \(tunDevice)") : "{enable: false}")",
                  "dns: \(try dnsSettings(root["dns"], raw: source))", "log-level: warning",
                  "external-controller: 127.0.0.1:\(controllerPort)", "secret: \(safeSecret)",
                  "profile: {store-selected: false, store-fake-ip: false}"]
        return lines.joined(separator: "\n") + "\n"
    }
    private static let tunSettings = "{enable: true, stack: mixed, auto-route: true, auto-detect-interface: true, dns-hijack: [any:53, tcp://any:53], route-exclude-address: [127.0.0.0/8, '::1/128', 100.64.0.0/10, 'fd7a:115c:a1e0::/48']}"

    private static func dnsSettings(_ source: YAMLValue?, raw: String) throws -> String {
        if let source, source.map == nil { throw LeapinError.invalidConfiguration("dns 需要对象格式，不能丢弃来源策略") }
        var dns = source?.map ?? [:]
        // Enable the kernel's resolver, without exposing an additional DNS listener.
        dns["enable"] = .scalar("true")
        dns["listen"] = .scalar("")
        if dns["nameserver"] == nil { dns["nameserver"] = .array([.scalar("https://1.1.1.1/dns-query")]) }
        // Keep block-form DNS verbatim (including future typed fields). Only
        // the two host-owned siblings are replaced, never nested policy keys.
        var block: [String] = []; var found = false; var isBlock = false
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if ["---", "..."].contains(trimmed) { continue }
            if !line.hasPrefix(" "), !line.hasPrefix("\t"), !trimmed.isEmpty, !trimmed.hasPrefix("#"), let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if found { break }
                if key == "dns" {
                    found = true
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    isBlock = value.isEmpty || value.hasPrefix("#")
                }
            } else if found { block.append(line) }
        }
        if found && isBlock {
            let indent = block.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.map { $0.prefix { $0 == " " }.count }.min() ?? 2
            let padding = String(repeating: " ", count: max(2, indent))
            var keep = true; var filtered: [String] = []
            for line in block {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if line.prefix(while: { $0 == " " }).count == indent, !trimmed.isEmpty, !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") {
                    let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    keep = !["listen", "enable"].contains(key)
                }
                if keep { filtered.append(line) }
            }
            filtered += [padding + "enable: true", padding + "listen: \"\""]
            if source?["nameserver"] == nil { filtered.append(padding + "nameserver: [https://1.1.1.1/dns-query]") }
            return "\n" + filtered.joined(separator: "\n")
        }
        return flow(.map(dns))
    }
    private static func flow(_ value: YAMLValue, key: String = "") -> String {
        func quote(_ s: String) -> String { let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes; return String(decoding: try! encoder.encode(s), as: UTF8.self) }
        switch value {
        case .null: return "null"
        case .scalar(let s):
            let bools: Set<String> = ["enable", "ipv6", "prefer-h3", "respect-rules", "use-hosts", "use-system-hosts", "geoip"]
            if bools.contains(key), let bool = value.bool { return bool ? "true" : "false" }
            if ["cache-size", "fake-ip-ttl"].contains(key), let number = Int(s) { return String(number) }
            return quote(s)
        case .array(let array): return "[" + array.map { flow($0, key: key) }.joined(separator: ", ") + "]"
        case .map(let map): return "{" + map.keys.sorted().map { quote($0) + ": " + flow(map[$0]!, key: $0) }.joined(separator: ", ") + "}"
        }
    }

}

private final class KernelOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        bytes.append(data)
        if bytes.count > 32_768 { bytes.removeFirst(bytes.count - 32_768) }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return Redactor.redact(String(decoding: bytes, as: UTF8.self))
    }
}

/// Owns exactly one child. All endpoints are loopback-only; callers cannot aim
/// the authenticated controller client at an arbitrary URL.
@MainActor
public final class ManagedMihomo: ObservableObject {
    @Published public private(set) var version: String?
    @Published public private(set) var proxyPort: UInt16?
    @Published public private(set) var running = false
    public var onUnexpectedExit: ((String) -> Void)?
    private var child: Process?
    private var output = KernelOutput()
    private var controllerPort: UInt16 = 0
    private var secret = ""
    private var generation = UUID()
    private var pipe: Pipe?
    private var runDirectory: URL?

    private let executableOverride: URL?
    public init(executable: URL? = nil) { executableOverride = executable }
    public var logs: String { output.text }

    public func discover() async {
        guard let executable = executableOverride ?? KernelExecutable.mihomo() else { version = nil; return }
        version = try? await KernelExecutable.version(at: executable)
    }

    public func validate(source: String, directory: URL, tun: Bool = false) async throws {
        guard let executable = executableOverride ?? KernelExecutable.mihomo() else {
            throw LeapinError.unsupported("未找到 Mihomo，请安装内核或在内核设置中指定路径")
        }
        let ports = try Self.reservePorts()
        defer { ports.descriptors.forEach { Darwin.close($0) } }
        let config = try MihomoConfiguration.managed(source, proxyPort: ports.ports[0],
                                                     controllerPort: ports.ports[1], secret: UUID().uuidString, tun: tun)
        try Self.write(config, directory: directory)
        try await Self.check(executable: executable, directory: directory)
    }

    public func start(source: String, directory: URL, tun: Bool = false) async throws -> UInt16 {
        guard !tun || geteuid() == 0 else { throw LeapinError.unsupported("TUN 需要管理员权限；当前图形包未安装特权服务，请使用已导出的终端启动包") }
        stop(waitForExit: tun)
        let run = UUID()
        generation = run
        guard let executable = executableOverride ?? KernelExecutable.mihomo() else { throw LeapinError.unsupported("未找到 Mihomo 内核") }
        let tunDevice = (1000...1100).map { "utun\($0)" }.first { name in name.withCString { if_nametoindex($0) } == 0 }
        guard !tun || tunDevice != nil else { throw LeapinError.connectionFailed("无法分配自有 TUN 设备名") }
        let ports = try Self.reservePorts()
        var held = ports.descriptors
        defer { held.forEach { Darwin.close($0) } }
        let proxy = ports.ports[0]
        controllerPort = ports.ports[1]
        secret = UUID().uuidString + UUID().uuidString
        let config = try MihomoConfiguration.managed(source, proxyPort: proxy, controllerPort: controllerPort, secret: secret, tun: tun, tunDevice: tunDevice ?? "utun198")
        try Self.write(config, directory: directory)
        runDirectory = directory
        try await Self.check(executable: executable, directory: directory)
        guard generation == run else { throw CancellationError() }
        let process = Process()
        let captured = KernelOutput()
        let stream = Pipe()
        output = captured
        pipe = stream
        stream.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { captured.append(data) }
        }
        process.executableURL = executable
        process.arguments = ["-d", directory.path, "-f", directory.appendingPathComponent("managed.yaml").path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stream
        process.standardError = stream
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self, self.generation == run else { return }
                self.running = false
                self.proxyPort = nil
                self.onUnexpectedExit?("Mihomo 已退出（\(ended.terminationStatus)）。\(captured.text.suffix(500))")
            }
        }
        held.forEach { Darwin.close($0) }; held = []
        child = process
        do {
            try process.run()
            for _ in 0..<50 {
                guard generation == run else { throw CancellationError() }
                guard process.isRunning else { throw LeapinError.connectionFailed("Mihomo 启动失败：\(captured.text.suffix(600))") }
                if let data = try? await request("version"),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = json["version"] as? String {
                    if tun, let tunDevice, tunDevice.withCString({ if_nametoindex($0) }) == 0 {
                        try await Task.sleep(nanoseconds: 100_000_000); continue
                    }
                    version = "Mihomo \(text)"
                    proxyPort = proxy
                    running = true
                    return proxy
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw LeapinError.timeout
        } catch {
            if generation == run { stop(waitForExit: tun) }
            throw error
        }
    }

    public func request(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 1) async throws -> Data {
        guard controllerPort > 0, !path.contains(".."), !path.contains("://"), !path.hasPrefix("/") else {
            throw LeapinError.invalidConfiguration("控制接口路径无效")
        }
        let url = URL(string: "http://127.0.0.1:\(controllerPort)/\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = timeout
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let options = URLSessionConfiguration.ephemeral
        options.connectionProxyDictionary = [:]
        let session = URLSession(configuration: options)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: req)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw LeapinError.connectionFailed("内核控制请求失败")
        }
        return data
    }

    public func stop(waitForExit: Bool = false) {
        generation = UUID()
        let process = child
        let directory = runDirectory
        runDirectory = nil
        child = nil
        running = false
        proxyPort = nil
        controllerPort = 0
        secret = ""
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        if let process, process.isRunning {
            process.terminate()
            if waitForExit {
                // The foreground TUN CLI must finish teardown before it exits;
                // an async timer cannot clean up after its parent has exited.
                let deadline = Date().addingTimeInterval(1.5)
                while process.isRunning && Date() < deadline { usleep(10_000) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                let killedDeadline = Date().addingTimeInterval(0.3)
                while process.isRunning && Date() < killedDeadline { usleep(10_000) }
                if let directory { try? FileManager.default.removeItem(at: directory) }
                return
            }
            // Never leave an owned child behind if SIGTERM is ignored.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                if let directory { try? FileManager.default.removeItem(at: directory) }
            }
        } else if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func write(_ text: String, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("managed.yaml")
        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func check(executable: URL, directory: URL) async throws {
        try await Task.detached {
            let result = try CommandRunner.run(executable: executable.path,
                arguments: ["-t", "-d", directory.path, "-f", directory.appendingPathComponent("managed.yaml").path], timeout: 15)
            guard result.succeeded else {
                throw LeapinError.invalidConfiguration("Mihomo 预检失败：\(Redactor.redact(result.tail(5)))")
            }
        }.value
    }

    private static func reservePorts() throws -> (ports: [UInt16], descriptors: [Int32]) {
        var descriptors: [Int32] = []
        var ports: [UInt16] = []
        do {
            for _ in 0..<2 {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { throw LeapinError.connectionFailed("无法分配本地端口") }
                descriptors.append(fd)
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                let bound = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                guard bound == 0 else { throw LeapinError.connectionFailed("本地端口分配失败") }
                var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                let got = withUnsafeMutablePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
                }
                guard got == 0 else { throw LeapinError.connectionFailed("无法读取本地端口") }
                ports.append(UInt16(bigEndian: addr.sin_port))
            }
            return (ports, descriptors)
        } catch { descriptors.forEach { Darwin.close($0) }; throw error }
    }
}
