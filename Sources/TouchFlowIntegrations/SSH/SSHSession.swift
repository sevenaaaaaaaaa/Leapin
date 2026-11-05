import Foundation
import Darwin
import TouchFlowCore

/// Owns the child process and all mutable state so that a nonisolated `deinit`
/// can tear everything down even while the actor is being released.
final class SSHProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _process: Process?
    private var _input: Pipe?
    private var _output: Pipe?
    private var _askpassDirectory: URL?
    private var _connected = false
    private var _firstOutputAt: Date?
    private var _errorTail = ""

    var process: Process? { lock.lock(); defer { lock.unlock() }; return _process }
    var inputPipe: Pipe? { lock.lock(); defer { lock.unlock() }; return _input }
    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return _connected }
    var firstOutputAt: Date? { lock.lock(); defer { lock.unlock() }; return _firstOutputAt }
    var errorTail: String { lock.lock(); defer { lock.unlock() }; return _errorTail }

    func install(process: Process, input: Pipe, output: Pipe, askpassDirectory: URL?) {
        lock.lock()
        _process = process
        _input = input
        _output = output
        _askpassDirectory = askpassDirectory
        _connected = false
        _firstOutputAt = nil
        _errorTail = ""
        lock.unlock()
    }

    func markConnected() {
        lock.lock(); _connected = true; lock.unlock()
    }

    func noteOutput(_ text: String) {
        lock.lock()
        if _firstOutputAt == nil { _firstOutputAt = Date() }
        _errorTail += text
        if _errorTail.count > 4096 { _errorTail = String(_errorTail.suffix(4096)) }
        lock.unlock()
    }

    /// Terminates the child, closes both pipes and removes the askpass script.
    /// Safe to call multiple times and from any thread.
    func teardown() {
        lock.lock()
        let process = _process
        let input = _input
        let output = _output
        let askpass = _askpassDirectory
        _process = nil
        _input = nil
        _output = nil
        _askpassDirectory = nil
        _connected = false
        lock.unlock()

        output?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        if let askpass {
            try? FileManager.default.removeItem(at: askpass)
        }
    }
}

/// Interactive SSH session backed by the system `ssh` binary.
///
/// Password authentication never touches argv or the log: a 0600 askpass helper
/// is written to a private temp directory, the password is passed through
/// `Process.environment`, and the helper is deleted when the session ends.
public actor SSHSession {
    private let box = SSHProcessBox()
    private var outputQueue = DispatchQueue(label: "com.touchflow.ssh.output", qos: .userInitiated)

    /// Called with decoded output (stdout + stderr merged). Invoked on a private
    /// serial queue, never on the main thread; hop to your own actor if needed.
    public var outputHandler: (@Sendable (String) -> Void)?

    public init() {}

    public func setOutputHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        outputHandler = handler
    }

    public var isConnected: Bool { box.isConnected }

    public func connect(host: String,
                        port: UInt16,
                        user: String,
                        password: String?,
                        keyPath: String?,
                        knownHosts: String) async throws {
        guard box.process == nil else {
            throw TouchFlowError.invalidConfiguration("SSH session is already connected")
        }
        let host = host.trimmingCharacters(in: .whitespaces)
        let user = user.trimmingCharacters(in: .whitespaces)
        guard host.isEmpty == false, user.isEmpty == false, port > 0 else {
            throw TouchFlowError.invalidConfiguration("host, user and port are required")
        }
        guard FileManager.default.isExecutableFile(atPath: SSHSession.sshPath) else {
            throw TouchFlowError.unsupported("/usr/bin/ssh not found")
        }

        var arguments = ["-tt", "-p", String(port)]
        arguments += ["-o", "ServerAliveInterval=15"]
        arguments += ["-o", "ConnectTimeout=10"]
        arguments += SSHSession.hostKeyArguments(knownHosts: knownHosts)
        if let keyPath, keyPath.isEmpty == false {
            arguments += ["-i", (keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        arguments += ["\(user)@\(host)"]

        var environment = ProcessInfo.processInfo.environment
        var askpassDirectory: URL?
        if let password {
            let directory = try SSHSession.makeAskpassDirectory()
            askpassDirectory = directory
            let script = directory.appendingPathComponent("askpass.sh")
            let body = "#!/bin/sh\nprintf '%s\\n' \"$TF_SSH_PASSWORD\"\n"
            do {
                try body.write(to: script, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw TouchFlowError.invalidConfiguration("cannot create askpass helper: \(error.localizedDescription)")
            }
            environment["SSH_ASKPASS"] = script.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = ":0"
            // Password travels only through the child environment, never argv/logs.
            environment["TF_SSH_PASSWORD"] = password
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHSession.sshPath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let handler = outputHandler
        let box = self.box
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = SSHSession.decode(data)
            box.noteOutput(text)
            handler?(text)
        }

        box.install(process: process, input: inputPipe, output: outputPipe, askpassDirectory: askpassDirectory)

        do {
            try process.run()
        } catch {
            box.teardown()
            throw TouchFlowError.connectionFailed("failed to launch ssh: \(error.localizedDescription)")
        }
        TFLog.shared.info("integrations.ssh", "connecting to \(user)@\(host):\(port)")

        // Success = first packet arrived, or the process is still alive after 3 s.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if process.isRunning == false { break }
            if box.firstOutputAt != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if process.isRunning == false {
            let tail = box.errorTail.trimmingCharacters(in: .whitespacesAndNewlines)
            async let status = SSHSession.exitStatus(of: process)
            box.teardown()
            let code = await status
            throw TouchFlowError.connectionFailed(
                "ssh exited with \(code): \(tail.isEmpty ? "no output" : String(tail.suffix(600)))")
        }
        box.markConnected()
        TFLog.shared.info("integrations.ssh", "session ready \(user)@\(host):\(port)")
    }

    /// Writes raw bytes to the remote shell. No newline is appended.
    public func write(_ text: String) async {
        guard let handle = box.inputPipe?.fileHandleForWriting else {
            TFLog.shared.warn("integrations.ssh", "write ignored: not connected")
            return
        }
        do {
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            TFLog.shared.error("integrations.ssh", "write failed: \(error.localizedDescription)")
        }
    }

    /// Best-effort terminal resize. `Process` gives us a pipe rather than a pty
    /// master, so TIOCSWINSZ usually fails; the call is kept for API completeness
    /// and so a future pty-based implementation can drop in unchanged.
    public func resize(cols: Int, rows: Int) async {
        guard cols > 0, rows > 0, let handle = box.inputPipe?.fileHandleForWriting else { return }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        if ioctl(handle.fileDescriptor, TIOCSWINSZ, &size) != 0 {
            TFLog.shared.debug("integrations.ssh", "resize ignored: stdin is not a tty")
        }
    }

    public func disconnect() async {
        box.teardown()
        TFLog.shared.info("integrations.ssh", "session closed")
    }

    deinit {
        box.teardown()
    }

    // MARK: - Helpers

    static let sshPath = "/usr/bin/ssh"

    /// `knownHosts` is either a policy (accept-new / yes / no / ask) or a file path.
    static func hostKeyArguments(knownHosts: String) -> [String] {
        let value = knownHosts.trimmingCharacters(in: .whitespaces)
        let policies: Set<String> = ["yes", "no", "ask", "accept-new"]
        if value.isEmpty {
            return ["-o", "StrictHostKeyChecking=accept-new"]
        }
        if policies.contains(value.lowercased()) {
            return ["-o", "StrictHostKeyChecking=\(value.lowercased())"]
        }
        let path = (value as NSString).expandingTildeInPath
        return ["-o", "UserKnownHostsFile=\(path)", "-o", "StrictHostKeyChecking=yes"]
    }

    static func makeAskpassDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("touchflow-ssh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private static func exitStatus(of process: Process) async -> Int32 {
        // `terminationStatus` is only meaningful once the process has exited.
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return process.isRunning ? -1 : process.terminationStatus
    }

    static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    /// Removes CSI escape sequences; colours are preserved by default because the
    /// terminal view renders them itself.
    public static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[a-zA-Z]", with: "", options: .regularExpression)
    }
}
