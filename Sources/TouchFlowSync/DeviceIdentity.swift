import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

// MARK: - Secret storage

public enum SecretStoreError: Error, LocalizedError {
    case keychain(OSStatus)
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "钥匙串操作失败（OSStatus \(status)）"
        case .invalidPayload:
            return "设备密钥内容无效"
        }
    }
}

/// Where the Ed25519 private key lives. The app uses the Keychain; tests and
/// throwaway CLI runs use the file/memory implementations so they never touch
/// the user's login keychain.
public protocol SecretStore: Sendable {
    func readSecret() throws -> Data?
    func writeSecret(_ data: Data) throws
    func deleteSecret() throws
}

#if canImport(Security)
/// Generic-password item in the login keychain. Only the 32-byte Ed25519 seed
/// is stored; the public key and fingerprint are derived, never persisted.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public let account: String

    public init(service: String = "com.touchflow.device", account: String = "identity.ed25519") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func readSecret() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SecretStoreError.keychain(status)
        }
        return data
    }

    public func writeSecret(_ data: Data) throws {
        try? deleteSecret()
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    public func deleteSecret() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw SecretStoreError.keychain(status)
        }
    }
}
#endif

/// 0600 file under a 0700 directory. Used by tfctl when the keychain is not
/// available (unsigned CLI, CI) and by integration tests.
public final class FileSecretStore: SecretStore, @unchecked Sendable {
    public let directory: URL
    public let fileName: String

    public init(directory: URL, fileName: String = "device.key") {
        self.directory = directory
        self.fileName = fileName
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    public var fileURL: URL { directory.appendingPathComponent(fileName) }

    public func readSecret() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    public func writeSecret(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func deleteSecret() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}

/// Process-lifetime store; lets tests create two independent devices in one run.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    public init(seed: Data? = nil) { self.data = seed }

    public func readSecret() throws -> Data? { lock.withLock { data } }
    public func writeSecret(_ data: Data) throws { lock.withLock { self.data = data } }
    public func deleteSecret() throws { lock.withLock { self.data = nil } }
}

// MARK: - Device identity

/// Ed25519 key pair plus the stable identifiers derived from it.
///
/// deviceID is the first 16 bytes of SHA-256(publicKey) as hex; fingerprint
/// groups 8 bytes into lowercase 4-hex blocks for out-of-band comparison.
public struct DeviceIdentity: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey
    public let publicKeyData: Data
    public let deviceID: String
    public let fingerprint: String

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
        self.publicKeyData = privateKey.publicKey.rawRepresentation
        let digest = Data(SHA256.hash(data: publicKeyData))
        self.deviceID = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let fp = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        self.fingerprint = stride(from: 0, to: fp.count, by: 4).map { offset -> String in
            let start = fp.index(fp.startIndex, offsetBy: offset)
            let end = fp.index(start, offsetBy: 4)
            return String(fp[start..<end])
        }.joined(separator: "-")
    }

    /// Restores a key from its 32-byte seed.
    public init(rawPrivateKey: Data) throws {
        guard rawPrivateKey.count == 32 else { throw SecretStoreError.invalidPayload }
        self.init(privateKey: try Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivateKey))
    }

    public func sign(_ payload: Data) throws -> Data {
        try privateKey.signature(for: payload)
    }

    public static func verify(signature: Data, payload: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: payload) else { return false }
        return true
    }

    public static func load(store: SecretStore) throws -> DeviceIdentity? {
        guard let seed = try store.readSecret() else { return nil }
        return try DeviceIdentity(rawPrivateKey: seed)
    }

    /// Returns the existing identity or creates and persists a fresh one.
    public static func loadOrCreate(store: SecretStore) throws -> DeviceIdentity {
        if let existing = try load(store: store) { return existing }
        let key = Curve25519.Signing.PrivateKey()
        let identity = DeviceIdentity(privateKey: key)
        try store.writeSecret(key.rawRepresentation)
        return identity
    }

    public static func encodePublicKey(_ data: Data) -> String {
        data.base64EncodedString()
    }

    public static func decodePublicKey(_ text: String) -> Data? {
        Data(base64Encoded: text)
    }
}
