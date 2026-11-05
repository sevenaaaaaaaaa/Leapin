import Foundation

/// A byte-oriented, full-duplex connection (client socket, outbound tunnel, ...).
public protocol ByteStream: AnyObject, Sendable {
    func write(_ data: Data) async throws
    /// Returns nil on clean EOF.
    func read(maxLength: Int) async throws -> Data?
    func close()
    var remoteDescription: String { get }
    var bytesRead: Int { get }
    var bytesWritten: Int { get }
}

/// Decides which outbound policy a connection should use.
public protocol RouteDeciding: Sendable {
    func decide(_ meta: ConnectionMeta) -> RouteDecision
}

/// Domain blocking (adblock / tracker / privacy lists).
public protocol DomainBlocking: Sendable {
    func verdict(for domain: String, thirdParty: Bool) -> BlockVerdict
    func cosmeticSelectors(for domain: String) -> [String]
}

public protocol FlowRecording: AnyObject, Sendable {
    func record(_ event: FlowEvent)
}

public protocol CaptureSink: AnyObject, Sendable {
    func capture(_ request: CapturedRequest)
}

/// Resolves hostnames to IPv4/IPv6 addresses using the configured DNS pipeline.
public protocol NameResolving: Sendable {
    func resolve(_ host: String) async throws -> [String]
}

public enum TouchFlowError: Error, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case connectionFailed(String)
    case protocolError(String)
    case blocked(String)
    case unsupported(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let s): return "Invalid configuration: \(s)"
        case .connectionFailed(let s): return "Connection failed: \(s)"
        case .protocolError(let s): return "Protocol error: \(s)"
        case .blocked(let s): return "Blocked: \(s)"
        case .unsupported(let s): return "Unsupported: \(s)"
        case .timeout: return "Timed out"
        }
    }
}
