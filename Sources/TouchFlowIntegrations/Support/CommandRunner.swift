import Foundation
import Darwin
import TouchFlowCore

/// Result of running an external command-line tool.
public struct CommandOutput: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    /// stdout followed by stderr (interleaving between the two is not preserved).
    public var combined: String {
        if stderr.isEmpty { return stdout }
        if stdout.isEmpty { return stderr }
        return stdout + "\n" + stderr
    }

    public var succeeded: Bool { status == 0 && !timedOut }

    /// Last N non-empty lines of the combined output — safe for error messages.
    public func tail(_ lines: Int = 6) -> String {
        let all = combined.components(separatedBy: .newlines)
            .filter { line in !line.trimmingCharacters(in: .whitespaces).isEmpty }
        return all.suffix(max(1, lines)).joined(separator: "\n")
    }
}

/// Thread-safe byte accumulator for the pipe reader threads.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newValue: Data) {
        lock.lock(); data = newValue; lock.unlock()
    }

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    func get() -> Data {
        lock.lock(); defer { lock.unlock() }; return data
    }
}

/// Small wrapper around `Process` that enforces a deadline and never leaves a pipe
/// reader blocked forever. Every shelled-out tool in this module goes through it,
/// so every external call has a timeout and captured stderr.
public enum CommandRunner {
    public static let defaultTimeout: TimeInterval = 10

    @discardableResult
    public static func run(executable: String,
                           arguments: [String],
                           timeout: TimeInterval = defaultTimeout,
                           environment: [String: String]? = nil,
                           currentDirectory: URL? = nil) throws -> CommandOutput {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw TouchFlowError.unsupported("missing executable at \(executable)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment { merged[key] = value }
            process.environment = merged
        }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        do {
            try process.run()
        } catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            _ = group.wait(timeout: .now() + 1)
            throw TouchFlowError.connectionFailed("failed to launch \(executable): \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while process.isRunning && Date() < deadline {
            usleep(10_000) // 10 ms polls
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            TFLog.shared.warn("integrations.cmd", "\(executable) timed out after \(timeout)s, terminating")
            process.terminate()
            let graceDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < graceDeadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        // Readers see EOF once the child and our write ends are gone.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        _ = group.wait(timeout: .now() + 3)

        let stdout = decode(outBox.get())
        let stderr = decode(errBox.get())
        // Reading `terminationStatus` while the child is still alive raises an
        // Objective-C exception that Swift cannot catch (SIGKILL may not have landed
        // yet). Report such a child as a timeout instead of crashing the host app.
        let exited = !process.isRunning
        let status: Int32 = exited ? process.terminationStatus : -1
        if !exited {
            TFLog.shared.error("integrations.cmd",
                               "\(executable) pid \(process.processIdentifier) survived SIGKILL; reporting timeout")
        }
        TFLog.shared.debug("integrations.cmd",
                           "\(executable) \(arguments.joined(separator: " ")) -> \(exited ? String(status) : "pid \(process.processIdentifier) still running")\(timedOut ? " (timeout)" : "")")
        return CommandOutput(status: status, stdout: stdout, stderr: stderr,
                             timedOut: timedOut || !exited)
    }

    /// Runs the command and maps timeout / non-zero exit to `TouchFlowError`.
    @discardableResult
    public static func runChecked(executable: String,
                                  arguments: [String],
                                  timeout: TimeInterval = defaultTimeout,
                                  environment: [String: String]? = nil,
                                  currentDirectory: URL? = nil) throws -> CommandOutput {
        let output = try run(executable: executable, arguments: arguments, timeout: timeout,
                             environment: environment, currentDirectory: currentDirectory)
        if output.timedOut { throw TouchFlowError.timeout }
        guard output.status == 0 else {
            let name = (executable as NSString).lastPathComponent
            throw TouchFlowError.connectionFailed("\(name) exited with \(output.status): \(output.tail())")
        }
        return output
    }

    static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}
