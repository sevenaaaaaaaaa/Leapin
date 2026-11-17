import Foundation
import Darwin
import LeapinCore
import LeapinIntegrations

/// One port the engine is about to bind, with the label the user sees.
public struct PortRequest: Sendable, Equatable {
    public var port: UInt16
    public var role: String
    public init(port: UInt16, role: String) { self.port = port; self.role = role }
}

/// Something already listening on a port we want.
public struct PortHolder: Sendable, Equatable {
    public var pid: Int32
    public var command: String
    /// launchd label when the holder is a service, e.g. "com.user.mihomo".
    public var service: String?
    public init(pid: Int32, command: String, service: String? = nil) {
        self.pid = pid; self.command = command; self.service = service
    }

    /// "mihomo（PID 61629，launchd 服务 com.user.mihomo）"
    public var describedWithService: String {
        var text = "\(command)（PID \(pid)"
        if let service { text += "，launchd 服务 \(service)" }
        return text + "）"
    }
}

public struct PortConflict: Sendable, Equatable {
    public var port: UInt16
    public var role: String
    public var holders: [PortHolder]
    public init(port: UInt16, role: String, holders: [PortHolder]) {
        self.port = port; self.role = role; self.holders = holders
    }

    /// "混合端口 7890 已被 mihomo 占用（PID 61629，launchd 服务 com.user.mihomo）"
    public var summary: String {
        let who = holders.map(\.describedWithService).joined(separator: "、")
        return "\(role) \(port) 已被 \(who) 占用"
    }
}

/// A mihomo that we did not start. A launchd instance rewrites the system proxy
/// and takes the same routes, so living beside the managed kernel is never silent.
public struct ForeignKernel: Sendable, Equatable {
    public var pid: Int32
    public var command: String
    public var service: String?
    public var managedByUs: Bool
    public init(pid: Int32, command: String, service: String? = nil, managedByUs: Bool = false) {
        self.pid = pid; self.command = command; self.service = service; self.managedByUs = managedByUs
    }
    public var label: String { service ?? command }
}

public struct PortReport: Sendable, Equatable {
    public var requests: [PortRequest]
    public var conflicts: [PortConflict]
    public var kernels: [ForeignKernel]
    /// True when the audit itself could not run (no lsof, timeout). Ports are then
    /// unknown, not free — the UI has to say so instead of claiming "no conflict".
    public var auditFailed: Bool
    public init(requests: [PortRequest] = [], conflicts: [PortConflict] = [],
                kernels: [ForeignKernel] = [], auditFailed: Bool = false) {
        self.requests = requests; self.conflicts = conflicts
        self.kernels = kernels; self.auditFailed = auditFailed
    }

    public var isClear: Bool { conflicts.isEmpty }

    /// Kernels we did not start: a launchd instance, or another app's.
    public var foreignKernels: [ForeignKernel] { kernels.filter { !$0.managedByUs } }

    /// A kernel launched from our own runtime directory that is still alive while
    /// the engine thinks it is stopped — the leftover that keeps a port busy.
    public var staleKernels: [ForeignKernel] { kernels.filter { $0.managedByUs } }

    public var foreignKernelNote: String? {
        if let stale = staleKernels.first {
            return "上一次受管内核没有收尾，进程还在（PID \(stale.pid)），端口仍被它占着；先结束它再启动。"
        }
        guard let kernel = foreignKernels.first else { return nil }
        return "检测到另一个 mihomo（\(kernel.label)，PID \(kernel.pid)）。它有自己的一套端口与路由，先确认要用哪一个，避免和受管内核互相覆盖。"
    }

    /// One paragraph the user can act on. Names the holder and the way out.
    public var summary: String? {
        guard !conflicts.isEmpty else { return nil }
        let lines = conflicts.map { "· " + $0.summary }
        return (["本地端口被占用，代理没有启动："] + lines + [
            "先停止占用者，或在「设置」里改用其他端口。launchd 服务可用：launchctl bootout gui/$(id -u) <服务名>",
        ]).joined(separator: "\n")
    }
}

/// Read-only port audit, run before the engine binds anything.
///
/// The check is a listener listing, not a bind probe: a second bind can succeed on
/// macOS under SO_REUSEADDR and then serve half the connections, which is exactly
/// the "it started but nothing works" failure this exists to stop.
public enum PortAudit {
    /// Ports that must be free for the given profile, in the order they are bound.
    public static func requests(mixed: UInt16, http: UInt16, socks: UInt16,
                                dns: UInt16?, control: UInt16?) -> [PortRequest] {
        var list: [PortRequest] = []
        if mixed > 0 { list.append(PortRequest(port: mixed, role: "混合端口")) }
        if http > 0, http != mixed { list.append(PortRequest(port: http, role: "HTTP 端口")) }
        if socks > 0, socks != mixed, socks != http { list.append(PortRequest(port: socks, role: "SOCKS 端口")) }
        if let dns, dns > 0 { list.append(PortRequest(port: dns, role: "DNS 端口")) }
        if let control, control > 0 { list.append(PortRequest(port: control, role: "控制端口")) }
        return list
    }

    public static func report(_ requests: [PortRequest],
                              excluding: Set<Int32> = [getpid()]) -> PortReport {
        var seen = Set<UInt16>()
        let unique = requests.filter { $0.port > 0 && seen.insert($0.port).inserted }
        var report = PortReport(requests: unique)
        guard !unique.isEmpty else { return report }

        let listing = listeners(on: unique.map { $0.port })
        report.auditFailed = listing.failed
        let services = launchdServices(for: Set(listing.holders.values.flatMap { $0 }.map { $0.pid }))
        let attached = listing.holders.mapValues { holders in
            holders.map { PortHolder(pid: $0.pid, command: $0.command, service: services[$0.pid]) }
        }
        report.conflicts = unique.compactMap { request in
            let holders = (attached[request.port] ?? []).filter { !excluding.contains($0.pid) }
            return holders.isEmpty ? nil : PortConflict(port: request.port, role: request.role, holders: holders)
        }
        report.kernels = kernels(excluding: excluding.union(Set(report.conflicts.flatMap { $0.holders.map { $0.pid } })))
        return report
    }

    // MARK: - lsof

    /// Ports and the processes listening on them. Never throws: a missing tool is
    /// reported as a failed audit so the caller can stay honest about not knowing.
    public static func listeners(on ports: [UInt16]) -> (holders: [UInt16: [PortHolder]], failed: Bool) {
        guard !ports.isEmpty else { return ([:], false) }
        let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let lsof else { return ([:], true) }
        var arguments = ["-nP", "-F", "pcn"]
        for port in ports { arguments.append("-iTCP:\(port)") }
        arguments.append("-sTCP:LISTEN")
        do {
            let result = try CommandRunner.run(executable: lsof, arguments: arguments, timeout: 4)
            // lsof exits 1 when nothing matches; that is "no listener", not a failure.
            guard result.succeeded || result.status == 1 else { return ([:], true) }
            return (parseListers(result.stdout, ports: Set(ports)), false)
        } catch {
            return ([:], true)
        }
    }

    /// Parses `lsof -F pcn` output. A process block is `p<pid>`, `c<command>`,
    /// then one `n<address>:<port>` line per matching socket.
    public static func parseListers(_ output: String, ports: Set<UInt16>) -> [UInt16: [PortHolder]] {
        var result: [UInt16: [PortHolder]] = [:]
        var pid: Int32 = 0
        var command = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            switch line.first {
            case "p":
                pid = Int32(line.dropFirst()) ?? 0
                command = ""
            case "c":
                command = String(line.dropFirst())
            case "n":
                guard let port = socketPort(String(line.dropFirst())), ports.contains(port), pid != 0 else { continue }
                var holders = result[port] ?? []
                if !holders.contains(where: { $0.pid == pid }) {
                    holders.append(PortHolder(pid: pid, command: command.isEmpty ? "pid \(pid)" : command))
                }
                result[port] = holders
            default:
                continue
            }
        }
        return result
    }

    /// "127.0.0.1:7890" / "*:7890" / "[::1]:7890" / "[::]:7890 (LISTEN)" → 7890.
    static func socketPort(_ name: String) -> UInt16? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let digits = trimmed[trimmed.index(after: colon)...].prefix { $0.isNumber }
        guard !digits.isEmpty, let port = Int(digits), port > 0, port <= 65_535 else { return nil }
        return UInt16(port)
    }

    // MARK: - launchd

    /// PID → launchd label, for the pids that actually came back as holders.
    public static func launchdServices(for pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let launchctl = ["/bin/launchctl", "/usr/bin/launchctl"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let launchctl, let result = try? CommandRunner.run(executable: launchctl, arguments: ["list"], timeout: 4),
              result.succeeded else { return [:] }
        return parseLaunchd(result.stdout, pids: pids)
    }

    /// `launchctl list` rows are "PID\tStatus\tLabel", with "-" for a stopped service.
    public static func parseLaunchd(_ output: String, pids: Set<Int32>) -> [Int32: String] {
        var result: [Int32: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3, let pid = Int32(columns[0]), pids.contains(pid) else { continue }
            let label = String(columns[2]).trimmingCharacters(in: .whitespaces)
            if !label.isEmpty { result[pid] = label }
        }
        return result
    }

    // MARK: - Foreign kernels

    /// A mihomo we did not start. The managed kernel is recognisable by the
    /// `kernel-runtime` directory it was launched with.
    public static func kernels(excluding: Set<Int32>) -> [ForeignKernel] {
        guard let pgrep = ["/usr/bin/pgrep", "/bin/pgrep"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let found = try? CommandRunner.run(executable: pgrep, arguments: ["-x", "mihomo"], timeout: 3) else { return [] }
        let pids = found.stdout.split(whereSeparator: { $0 == "\n" || $0 == " " }).compactMap { Int32($0) }
            .filter { !excluding.contains($0) }
        guard !pids.isEmpty else { return [] }
        var commands: [Int32: String] = [:]
        if let ps = ["/bin/ps", "/usr/bin/ps"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
           let listing = try? CommandRunner.run(executable: ps,
                                                arguments: ["-o", "pid=,command=", "-p", pids.map(String.init).joined(separator: ",")],
                                                timeout: 3), listing.succeeded {
            commands = parseProcessList(listing.stdout)
        }
        let services = launchdServices(for: Set(pids))
        return pids.map { pid in
            let command = commands[pid] ?? "mihomo"
            return ForeignKernel(pid: pid, command: command, service: services[pid],
                                 managedByUs: command.contains("kernel-runtime"))
        }.sorted { $0.pid < $1.pid }
    }

    /// `ps -o pid=,command=` → pid: full command line.
    public static func parseProcessList(_ output: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.drop { $0 == " " }
            let digits = trimmed.prefix { $0.isNumber }
            guard let pid = Int32(digits), pid > 0 else { continue }
            let rest = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { result[pid] = rest }
        }
        return result
    }
}
