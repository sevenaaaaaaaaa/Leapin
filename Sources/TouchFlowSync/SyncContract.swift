import Foundation
import CryptoKit
import TouchFlowCore

// MARK: - Wire types

public enum SyncError: Error, LocalizedError {
    case badRequest(String)
    case unauthorized(String)
    case notPaired
    case replay
    case staleTimestamp
    case badPairingCode
    case pairingExpired
    case http(Int)
    case malformedResponse(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .badRequest(let m): return "同步请求无效：\(m)"
        case .unauthorized(let m): return "同步鉴权失败：\(m)"
        case .notPaired: return "设备尚未配对"
        case .replay: return "同步请求重放"
        case .staleTimestamp: return "同步请求时间戳过期"
        case .badPairingCode: return "配对码错误"
        case .pairingExpired: return "配对码已过期"
        case .http(let code): return "同步服务返回 \(code)"
        case .malformedResponse(let m): return "同步响应无法解析：\(m)"
        case .transport(let m): return "同步连接失败：\(m)"
        }
    }
}

/// Public description of a device; safe to send over the LAN.
public struct SyncDevice: Codable, Sendable, Hashable {
    public var deviceID: String
    public var name: String
    public var publicKey: String
    public var fingerprint: String

    public init(deviceID: String, name: String, publicKey: String, fingerprint: String) {
        self.deviceID = deviceID
        self.name = name
        self.publicKey = publicKey
        self.fingerprint = fingerprint
    }

    public init(identity: DeviceIdentity, name: String) {
        self.init(deviceID: identity.deviceID, name: name,
                  publicKey: DeviceIdentity.encodePublicKey(identity.publicKeyData),
                  fingerprint: identity.fingerprint)
    }

    public var publicKeyData: Data? { DeviceIdentity.decodePublicKey(publicKey) }
}

public struct SyncManifest: Codable, Sendable {
    public var device: SyncDevice
    public var versions: [ProfileVersion]
    public var pointers: [String: ActivePointer]
    public var generatedAtMs: Int64

    public init(device: SyncDevice, versions: [ProfileVersion],
                pointers: [String: ActivePointer], generatedAtMs: Int64) {
        self.device = device
        self.versions = versions
        self.pointers = pointers
        self.generatedAtMs = generatedAtMs
    }
}

public struct PairRequest: Codable, Sendable {
    public var code: String
    public var device: SyncDevice

    public init(code: String, device: SyncDevice) {
        self.code = code
        self.device = device
    }
}

public struct PairResponse: Codable, Sendable {
    public var ok: Bool
    public var device: SyncDevice

    public init(ok: Bool, device: SyncDevice) {
        self.ok = ok
        self.device = device
    }
}

public struct AnnounceRequest: Codable, Sendable {
    public var device: SyncDevice
    public var pointers: [String: ActivePointer]
    public var versions: [ProfileVersion]

    public init(device: SyncDevice, pointers: [String: ActivePointer], versions: [ProfileVersion]) {
        self.device = device
        self.pointers = pointers
        self.versions = versions
    }
}

public struct AnnounceResponse: Codable, Sendable {
    public var accepted: Bool
    public var needVersions: [String]
    public var pointers: [String: ActivePointer]

    public init(accepted: Bool, needVersions: [String], pointers: [String: ActivePointer]) {
        self.accepted = accepted
        self.needVersions = needVersions
        self.pointers = pointers
    }
}

// MARK: - Pairing code

public enum PairingCode {
    /// Six digits, uniformly distributed. Short-lived and single-use; the code
    /// is what authenticates the first exchange on a plaintext LAN link.
    public static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0...999_999, using: &generator))
    }

    public static func normalize(_ raw: String) -> String {
        raw.filter { $0.isNumber }.prefix(6).description
    }
}

// MARK: - Signed requests

/// Ed25519-signed HTTP envelope. Covers method, path, body hash, timestamp and
/// a random nonce so a captured request cannot be replayed after the ±300 s
/// window without also replaying the nonce cache on the server.
public enum SyncAuth {
    public static let headerDevice = "X-TF-Device"
    public static let headerTimestamp = "X-TF-Timestamp"
    public static let headerNonce = "X-TF-Nonce"
    public static let headerSignature = "X-TF-Signature"
    public static let toleranceMs: Int64 = 300_000

    public static func canonical(method: String, path: String, body: Data,
                                 timestampMs: Int64, nonce: String) -> Data {
        let bodyHash = Data(SHA256.hash(data: body)).map { String(format: "%02x", $0) }.joined()
        return Data("TF-SYNC-1\n\(method.uppercased())\n\(path)\n\(bodyHash)\n\(timestampMs)\n\(nonce)".utf8)
    }

    public static func headers(identity: DeviceIdentity, method: String, path: String,
                               body: Data, now: Date = Date(), nonce: String? = nil) -> [String: String] {
        let ts = Int64(now.timeIntervalSince1970 * 1000)
        let n = nonce ?? PairingCode.make() + PairingCode.make()
        let payload = canonical(method: method, path: path, body: body, timestampMs: ts, nonce: n)
        let signature = (try? identity.sign(payload)) ?? Data()
        return [
            headerDevice: identity.deviceID,
            headerTimestamp: String(ts),
            headerNonce: n,
            headerSignature: signature.map { String(format: "%02x", $0) }.joined(),
        ]
    }

    public static func verify(headers: [String: String], method: String, path: String,
                              body: Data, peerPublicKey: Data, now: Date = Date()) throws {
        guard let device = headers[headerDevice], !device.isEmpty,
              let tsText = headers[headerTimestamp], let ts = Int64(tsText),
              let nonce = headers[headerNonce], nonce.count >= 8,
              let sigHex = headers[headerSignature], let signature = Data(hexString: sigHex) else {
            throw SyncError.unauthorized("缺少签名头")
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        guard abs(nowMs - ts) <= toleranceMs else { throw SyncError.staleTimestamp }
        let payload = canonical(method: method, path: path, body: body, timestampMs: ts, nonce: nonce)
        guard DeviceIdentity.verify(signature: signature, payload: payload, publicKey: peerPublicKey) else {
            throw SyncError.unauthorized("签名不匹配")
        }
    }
}


// MARK: - Local JSON

/// The runtime's ISO-8601 coders live in TouchFlowRuntime; the sync module is
/// lower in the graph, so it keeps its own pair with identical settings.
extension JSONEncoder {
    static var sync: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var sync: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            let hi = chars[index], lo = chars[index + 1]
            guard let h = hi.hexDigitValue, let l = lo.hexDigitValue else { return nil }
            bytes.append(UInt8(h << 4 | l))
            index += 2
        }
        self.init(bytes)
    }
}
