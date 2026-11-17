import XCTest
import Darwin
import LeapinCore
@testable import LeapinRuntime

final class PortAuditTests: XCTestCase {
    private func temporaryStore() throws -> ProfileStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ProfileStore(root: root)
    }

    /// A real listening socket, so lsof has something to find.
    private func listeningSocket() throws -> (port: UInt16, descriptor: Int32) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LeapinError.connectionFailed("socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { Darwin.close(fd); throw LeapinError.connectionFailed("bind") }
        guard Darwin.listen(fd, 1) == 0 else { Darwin.close(fd); throw LeapinError.connectionFailed("listen") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }) == 0 else { Darwin.close(fd); throw LeapinError.connectionFailed("getsockname") }
        return (UInt16(bigEndian: address.sin_port), fd)
    }

    // MARK: Parsing

    func testParsesLsofBlocks() {
        let output = """
        p61629
        cmihomo
        n127.0.0.1:7899
        n127.0.0.1:9299
        p4242
        cnginx
        n*:7890
        """
        let holders = PortAudit.parseListers(output, ports: [7890, 7899])
        XCTAssertEqual(holders[7899]?.first?.pid, 61629)
        XCTAssertEqual(holders[7899]?.first?.command, "mihomo")
        XCTAssertEqual(holders[7890]?.first?.command, "nginx")
        XCTAssertNil(holders[9299], "只报告被询问的端口")
    }

    func testParsesIPv6AndRejectsGarbageAddresses() {
        let output = """
        p7
        cnode
        n[::1]:5354
        p8
        cubroken
        nnostril
        """
        let holders = PortAudit.parseListers(output, ports: [5354])
        XCTAssertEqual(holders[5354]?.first?.pid, 7)
        XCTAssertEqual(PortAudit.parseListers(output, ports: [5]), [:])
    }

    func testParsesLaunchdTable() {
        let output = """
        PID	Status	Label
        -	0	com.apple.whatever
        61629	0	com.user.mihomo
        900	0	com.apple.other
        """
        let labels = PortAudit.parseLaunchd(output, pids: [61629, 900, 12345])
        XCTAssertEqual(labels[61629], "com.user.mihomo")
        XCTAssertEqual(labels[900], "com.apple.other")
        XCTAssertNil(labels[12345])
    }

    func testParsesProcessList() {
        let output = """
          61629 /opt/homebrew/bin/mihomo -d /Users/x/.config/mihomo
          42     /Applications/Leapin.app/Contents/MacOS/LeapinApp
        """
        let commands = PortAudit.parseProcessList(output)
        XCTAssertEqual(commands[61629], "/opt/homebrew/bin/mihomo -d /Users/x/.config/mihomo")
        XCTAssertEqual(commands[42], "/Applications/Leapin.app/Contents/MacOS/LeapinApp")
    }

    // MARK: Live audit

    func testFindsARealListenerAndNamesIt() throws {
        let (port, fd) = try listeningSocket()
        defer { Darwin.close(fd) }

        let report = PortAudit.report([PortRequest(port: port, role: "混合端口")], excluding: [])
        XCTAssertFalse(report.auditFailed, "lsof 应该可用")
        let conflict = try XCTUnwrap(report.conflicts.first)
        XCTAssertEqual(conflict.port, port)
        XCTAssertEqual(conflict.role, "混合端口")
        XCTAssertFalse(conflict.holders.isEmpty)
        XCTAssertTrue(conflict.summary.contains("\(port)"))
        XCTAssertTrue(conflict.summary.contains("占用"))
        let summary = try XCTUnwrap(report.summary)
        XCTAssertTrue(summary.contains("代理没有启动"), summary)
        XCTAssertTrue(summary.contains("launchctl bootout"), "错误里必须给出可执行的下一步")
    }

    func testFreePortIsClear() throws {
        let (port, fd) = try listeningSocket()
        Darwin.close(fd)   // released, nothing listens any more
        let report = PortAudit.report([PortRequest(port: port, role: "混合端口")], excluding: [])
        XCTAssertFalse(report.conflicts.contains { $0.port == port })
    }

    func testExcludingOurOwnPidHidesIt() throws {
        let (port, fd) = try listeningSocket()
        defer { Darwin.close(fd) }
        let report = PortAudit.report([PortRequest(port: port, role: "混合端口")])
        XCTAssertTrue(report.conflicts.isEmpty, "自己的监听不算冲突")
    }

    func testStaleKernelIsNamedBeforeAForeignOne() {
        let stale = PortReport(kernels: [ForeignKernel(pid: 42, command: "mihomo -d /x/kernel-runtime/y", managedByUs: true)])
        XCTAssertEqual(stale.staleKernels.count, 1)
        XCTAssertTrue(stale.foreignKernels.isEmpty)
        XCTAssertTrue(stale.foreignKernelNote?.contains("上一次受管内核") ?? false, stale.foreignKernelNote ?? "")

        let foreign = PortReport(kernels: [ForeignKernel(pid: 7, command: "/opt/homebrew/bin/mihomo -d /Users/x/.config/mihomo",
                                                         service: "com.user.mihomo")])
        XCTAssertTrue(foreign.foreignKernels.count == 1)
        XCTAssertTrue(foreign.staleKernels.isEmpty)
        XCTAssertTrue(foreign.foreignKernelNote?.contains("com.user.mihomo") ?? false)
        XCTAssertNil(PortReport().foreignKernelNote)
    }

    func testOwnPidsNeverIncludeAZeroChild() {
        XCTAssertEqual(LeapinEngine.ownPIDs(nil), [getpid()])
        XCTAssertEqual(LeapinEngine.ownPIDs(0), [getpid()])
        XCTAssertEqual(LeapinEngine.ownPIDs(1234), [getpid(), 1234])
    }

    func testRequestsSkipDuplicateAndZeroPorts() {
        let requests = PortAudit.requests(mixed: 7890, http: 7890, socks: 0, dns: nil, control: 7900)
        XCTAssertEqual(requests.map(\.port), [7890, 7900])
        XCTAssertEqual(requests.map(\.role), ["混合端口", "控制端口"])
    }

    // MARK: Engine

    /// A listener in *another* process, which is what a launchd mihomo is. The
    /// in-process socket cannot stand in for it: the audit deliberately ignores
    /// this app's own descriptors.
    private func foreignListener() throws -> (port: UInt16, process: Process) {
        let (port, fd) = try listeningSocket()
        Darwin.close(fd)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        server.arguments = ["-l", "127.0.0.1", "\(port)"]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        addTeardownBlock { if server.isRunning { server.terminate() } }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !PortAudit.listeners(on: [port]).holders.isEmpty { return (port, server) }
            usleep(50_000)
        }
        throw LeapinError.connectionFailed("外部监听进程没有就绪")
    }

    @MainActor
    func testStartFailsFastWithAReadablePortMessage() async throws {
        let (port, _) = try foreignListener()
        let store = try temporaryStore()
        let profile = Profile(name: "Busy",
                              general: GeneralConfig(mixedPort: port, httpPort: 0, socksPort: 0,
                                                     captureEnabled: false, dnsHijack: false,
                                                     controlEnabled: false),
                              rules: [Rule(kind: .match, value: "", policy: "DIRECT")])
        _ = try store.save(profile)
        store.activeProfileID = profile.id

        let engine = LeapinEngine(store: store)
        await engine.start()

        guard case .failed(let message) = engine.state else {
            return XCTFail("端口被占用时必须失败，实际：\(engine.state)")
        }
        XCTAssertTrue(message.contains("\(port)"), message)
        XCTAssertTrue(message.contains("占用"), message)
        XCTAssertTrue(message.contains("nc"), "错误里要指名占用的进程：\(message)")
        XCTAssertNotNil(engine.lastError)
    }

    @MainActor
    func testPortRequestsCoverOnlyWhatTheProfileActuallyBinds() throws {
        let store = try temporaryStore()
        let profile = Profile(name: "Ports",
                              general: GeneralConfig(mixedPort: 7890, httpPort: 7891, socksPort: 7892,
                                                     captureEnabled: false, dnsHijack: true,
                                                     controlEnabled: true, controlPort: 7900),
                              rules: [Rule(kind: .match, value: "", policy: "DIRECT")])
        let native = LeapinEngine.portRequests(for: profile, kernel: .native)
        XCTAssertEqual(native.map(\.port), [7890, 7891, 7892, profile.dns.listenPort, 7900])

        let mihomo = LeapinEngine.portRequests(for: profile, kernel: .mihomo)
        XCTAssertEqual(mihomo.map(\.port), [7890, 7891, 7892, 7900],
                       "DNS 劫持只在原生内核下起监听")
    }
}
