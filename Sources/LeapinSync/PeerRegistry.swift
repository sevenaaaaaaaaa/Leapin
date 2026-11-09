import Foundation

/// A device that has completed the pairing handshake. Its public key is the
/// only thing accepted for signed requests afterwards.
public struct SyncPeer: Codable, Sendable, Hashable {
    public var device: SyncDevice
    public var pairedAtMs: Int64
    public var lastSeenMs: Int64
    /// "read" | "control" | "write" — kept for P2 scope checks.
    public var scopes: [String]

    public init(device: SyncDevice, pairedAtMs: Int64, lastSeenMs: Int64, scopes: [String]) {
        self.device = device
        self.pairedAtMs = pairedAtMs
        self.lastSeenMs = lastSeenMs
        self.scopes = scopes
    }

    public func allows(_ scope: String) -> Bool { scopes.contains(scope) }
}

/// Pinned peers, one JSON file per device id under root/peers.
public final class PeerRegistry: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private let fm = FileManager.default

    public init(root: URL) {
        self.root = root
        try? fm.createDirectory(at: root, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    }

    private func url(_ deviceID: String) -> URL {
        root.appendingPathComponent("\(deviceID).json")
    }

    @discardableResult
    public func upsert(_ device: SyncDevice, at date: Date = Date(),
                       scopes: [String] = ["read", "control", "write"]) -> SyncPeer {
        lock.withLock {
            let ms = Int64(date.timeIntervalSince1970 * 1000)
            // peer(deviceID:) must not be used here: NSLock is not recursive and
            // this call already holds it. The *Locked helpers assume the lock.
            let existing = peerLocked(device.deviceID)
            let peer = SyncPeer(device: device, pairedAtMs: existing?.pairedAtMs ?? ms,
                                lastSeenMs: ms, scopes: scopes)
            if let data = try? JSONEncoder.sync.encode(peer) {
                try? data.write(to: url(device.deviceID), options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600],
                                      ofItemAtPath: url(device.deviceID).path)
            }
            return peer
        }
    }

    public func peer(deviceID: String) -> SyncPeer? {
        lock.withLock { peerLocked(deviceID) }
    }

    /// Caller must already hold the lock (NSLock is not recursive).
    private func peerLocked(_ deviceID: String) -> SyncPeer? {
        guard let data = try? Data(contentsOf: url(deviceID)) else { return nil }
        return try? JSONDecoder.sync.decode(SyncPeer.self, from: data)
    }

    public func all() -> [SyncPeer] {
        lock.withLock {
            guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
            return files.filter { $0.pathExtension == "json" }
                .compactMap { try? JSONDecoder.sync.decode(SyncPeer.self, from: Data(contentsOf: $0)) }
                .sorted { $0.device.name < $1.device.name }
        }
    }

    public func remove(deviceID: String) {
        lock.withLock { try? fm.removeItem(at: url(deviceID)) }
    }

    public func touch(deviceID: String, at date: Date = Date()) {
        lock.withLock {
            guard var peer = peerLocked(deviceID) else { return }
            peer.lastSeenMs = Int64(date.timeIntervalSince1970 * 1000)
            if let data = try? JSONEncoder.sync.encode(peer) {
                try? data.write(to: url(deviceID), options: .atomic)
            }
        }
    }
}
