import Foundation
import LeapinCore
import LeapinNet

/// Background latency prober behind url-test / fallback groups.
///
/// Probes are plain TCP connects through the real dial path (including the proxy
/// handshake for SS/Trojan), so a node that resolves but cannot carry traffic shows
/// up as dead instead of "0 ms because we never tried".
public final class HealthProber: @unchecked Sendable {
    public struct Probe: Sendable {
        /// Health-table key (the outbound name).
        public var name: String
        public var outbound: OutboundConfig
        public var host: String
        public var port: UInt16

        public init(name: String, outbound: OutboundConfig, host: String, port: UInt16) {
            self.name = name; self.outbound = outbound; self.host = host; self.port = port
        }
    }

    private let dialer: OutboundDialer
    private let probes: [Probe]
    private let interval: TimeInterval
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var running = false

    public init(dialer: OutboundDialer, probes: [Probe],
                interval: TimeInterval = 60, timeout: TimeInterval = 4) {
        self.dialer = dialer
        self.probes = probes
        self.interval = max(interval, 10)
        self.timeout = timeout
    }

    public func start() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !running, !probes.isEmpty else { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.probeAll()
                let sleep = UInt64(self.interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleep)
            }
        }
    }

    public func stop() {
        let pending = lock.withLock { () -> Task<Void, Never>? in
            running = false
            let task = self.task
            self.task = nil
            return task
        }
        pending?.cancel()
    }

    /// One round over every probe, at most four at a time.
    public func probeAll() async {
        let probes = self.probes
        guard !probes.isEmpty else { return }
        var start = 0
        while start < probes.count {
            let end = min(start + 4, probes.count)
            let chunk = Array(probes[start..<end])
            await withTaskGroup(of: Void.self) { group in
                for probe in chunk {
                    group.addTask { await self.probe(probe) }
                }
            }
            start = end
        }
    }

    private func probe(_ probe: Probe) async {
        let started = Date()
        do {
            let stream = try await withThrowingTaskGroup(of: ByteStream.self) { group -> ByteStream in
                group.addTask {
                    try await self.dialer.connect(via: probe.outbound, host: probe.host, port: probe.port)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                    throw LeapinError.timeout
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw LeapinError.timeout }
                return first
            }
            stream.close()
            let ms = max(1, Int(Date().timeIntervalSince(started) * 1000))
            LPHealth.shared.record(name: probe.name, latencyMs: ms)
            LPLog.shared.debug("health", "\(probe.name) \(ms)ms -> \(probe.host):\(probe.port)")
        } catch {
            LPHealth.shared.record(name: probe.name, latencyMs: nil, error: error.localizedDescription)
            LPLog.shared.debug("health", "\(probe.name) failed: \(error.localizedDescription)")
        }
    }
}
