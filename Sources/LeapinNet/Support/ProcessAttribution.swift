import Foundation
import LeapinCore
#if os(macOS)
import CLeapinProc
#endif

/// The local process behind a proxied connection, resolved through libproc.
public struct ClientProcess: Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var path: String?
    public var bundleID: String?

    public init(pid: Int32, name: String, path: String?, bundleID: String?) {
        self.pid = pid
        self.name = name
        self.path = path
        self.bundleID = bundleID
    }

    /// What the UI should show: the app name when we know it, else the executable name.
    public var displayName: String {
        if let name = name.split(separator: "/").last.map(String.init), !name.isEmpty { return name }
        return bundleID ?? "pid \(pid)"
    }
}

/// Maps a proxied connection back to the process that opened it.
///
/// A proxy only sees an IP and an ephemeral port, so "which app is this?" needs the
/// kernel socket table. Enumerating it costs tens of milliseconds, which is far too
/// much per connection, so we snapshot every TCP owner at most once a second and
/// answer lookups from that index. Attribution never blocks traffic: a miss simply
/// means the caller gets nil and records an unknown source.
public final class ProcessAttributor: @unchecked Sendable {
    public static let shared = ProcessAttributor()

    private struct Key: Hashable {
        var localPort: UInt16
        var remotePort: UInt16
    }

    private let lock = NSLock()
    private var owners: [Key: Int32] = [:]
    private var snapshotAt: Date?
    private var details: [Int32: ClientProcess] = [:]
    private var misses: Set<Int32> = []
    private let refreshInterval: TimeInterval = 1.0
    private let enabled: Bool

    public init(enabled: Bool = ProcessAttributor.defaultEnabled) {
        self.enabled = enabled
    }

    public static var defaultEnabled: Bool {
        ProcessInfo.processInfo.environment["LEAPIN_NO_PROCESS_ATTRIBUTION"] == nil
    }

    /// Attribution for the accepted connection whose client port is `localPort`
    /// and whose destination port is this proxy's listener.
    public func process(localPort: UInt16, remotePort: UInt16) -> ClientProcess? {
        #if os(macOS)
        guard enabled, localPort != 0, remotePort != 0 else { return nil }
        let key = Key(localPort: localPort, remotePort: remotePort)
        let pid: Int32? = lock.withLock {
            if snapshotAt == nil || Date().timeIntervalSince(snapshotAt!) > refreshInterval {
                refreshLocked()
            }
            return owners[key]
        }
        guard let pid, pid > 0 else { return nil }
        return describe(pid)
        #else
        // iOS sandboxes every other process: the kernel socket table is not readable,
        // so a connection can never be attributed to an app. Callers show "unknown".
        return nil
        #endif
    }

    /// Drops caches; used by tests and when the engine stops.
    public func reset() {
        lock.withLock {
            owners.removeAll()
            details.removeAll()
            misses.removeAll()
            snapshotAt = nil
        }
    }

    private func describe(_ pid: Int32) -> ClientProcess? {
        let cached = lock.withLock { () -> ClientProcess?? in
            if let hit = details[pid] { return .some(hit) }
            if misses.contains(pid) { return .some(nil) }
            return nil
        }
        if let cached { return cached }
        let resolved = Self.lookup(pid)
        lock.withLock {
            if let resolved { details[pid] = resolved } else { misses.insert(pid) }
            if details.count > 256 { details.removeAll() }
            if misses.count > 256 { misses.removeAll() }
        }
        return resolved
    }

    /// Rebuilds the port -> pid index from one libproc sweep.
    private func refreshLocked() {
        #if os(macOS)
        var capacity = 1024
        var rows: [leapin_tcp_owner] = []
        for _ in 0..<4 {
            var buffer = [leapin_tcp_owner](repeating: leapin_tcp_owner(local_port: 0, remote_port: 0, pid: 0),
                                        count: capacity)
            let result = buffer.withUnsafeMutableBufferPointer { pointer in
                leapin_list_tcp_owners(pointer.baseAddress, Int32(pointer.count))
            }
            if result >= 0 {
                rows = Array(buffer.prefix(Int(result)))
                break
            }
            capacity = max(capacity * 2, Int(-result))
        }
        var index: [Key: Int32] = [:]
        index.reserveCapacity(rows.count)
        for row in rows where row.pid > 0 {
            index[Key(localPort: row.local_port, remotePort: row.remote_port)] = row.pid
        }
        owners = index
        snapshotAt = Date()
        #endif
    }

    private static func lookup(_ pid: Int32) -> ClientProcess? {
        #if os(macOS)
        var nameBuffer = [CChar](repeating: 0, count: 512)
        let nameLen = nameBuffer.withUnsafeMutableBufferPointer { pointer in
            leapin_pid_name(pid, pointer.baseAddress, Int32(pointer.count))
        }
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLen = pathBuffer.withUnsafeMutableBufferPointer { pointer in
            leapin_pid_path(pid, pointer.baseAddress, Int32(pointer.count))
        }
        let path = pathLen > 0 ? String(cString: pathBuffer) : nil
        let name = nameLen > 0 ? String(cString: nameBuffer) : (path.map { ($0 as NSString).lastPathComponent } ?? "")
        guard !name.isEmpty || path != nil else { return nil }
        return ClientProcess(pid: pid, name: name, path: path, bundleID: bundleID(forExecutable: path))
        #else
        _ = pid
        return nil
        #endif
    }

    /// Walks up to the enclosing .app so Chrome reports its app bundle, not the
    /// helper executable path.
    private static func bundleID(forExecutable path: String?) -> String? {
        guard let path else { return nil }
        var url = URL(fileURLWithPath: path)
        for _ in 0..<6 {
            if url.pathExtension == "app" {
                return Bundle(url: url)?.bundleIdentifier
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path || parent.path == "/" { break }
            url = parent
        }
        return nil
    }
}
