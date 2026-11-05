import Foundation
import CryptoKit
import TouchFlowCore

// MARK: - Cipher suite

/// Shadowsocks AEAD ciphers (SIP004) that can be built from CryptoKit primitives.
public enum ShadowsocksCipher: String, Sendable, CaseIterable {
    case aes256gcm = "aes-256-gcm"
    case chacha20IetfPoly1305 = "chacha20-ietf-poly1305"

    public var keyLength: Int { 32 }
    public var saltLength: Int { 32 }
    public var tagLength: Int { 16 }
    /// Maximum plaintext chunk accepted by the framing (length field is 2 bytes,
    /// and SIP004 caps a chunk at 0x3FFF).
    public static let maxChunk = 0x3FFF

    /// Normalises database spellings such as `AEAD_AES_256_GCM` or `chacha20-poly1305`.
    public init?(_ raw: String) {
        let normalised = raw
            .lowercased()
            .replacingOccurrences(of: "aead_", with: "")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "chacha20-poly1305", with: "chacha20-ietf-poly1305")
        guard let cipher = ShadowsocksCipher(rawValue: normalised) else { return nil }
        self = cipher
    }

    public func seal(_ plaintext: Data, key: SymmetricKey, nonce: Data) throws -> Data {
        guard nonce.count == 12 else {
            throw TouchFlowError.protocolError("shadowsocks: nonce must be 12 bytes")
        }
        switch self {
        case .aes256gcm:
            guard let box = try? AES.GCM.Nonce(data: nonce) else {
                throw TouchFlowError.protocolError("shadowsocks: invalid AES-GCM nonce")
            }
            let sealed = try AES.GCM.seal(plaintext, using: key, nonce: box)
            return sealed.ciphertext + sealed.tag
        case .chacha20IetfPoly1305:
            guard let box = try? ChaChaPoly.Nonce(data: nonce) else {
                throw TouchFlowError.protocolError("shadowsocks: invalid ChaChaPoly nonce")
            }
            let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: box)
            return sealed.ciphertext + sealed.tag
        }
    }

    public func open(_ ciphertext: Data, key: SymmetricKey, nonce: Data) throws -> Data {
        guard ciphertext.count >= tagLength else {
            throw TouchFlowError.protocolError("shadowsocks: ciphertext shorter than tag")
        }
        guard nonce.count == 12 else {
            throw TouchFlowError.protocolError("shadowsocks: nonce must be 12 bytes")
        }
        let body = ciphertext.prefix(ciphertext.count - tagLength)
        let tag = ciphertext.suffix(tagLength)
        do {
            switch self {
            case .aes256gcm:
                guard let nonceBox = try? AES.GCM.Nonce(data: nonce) else {
                    throw TouchFlowError.protocolError("shadowsocks: invalid AES-GCM nonce")
                }
                let box = try AES.GCM.SealedBox(nonce: nonceBox, ciphertext: body, tag: tag)
                return try AES.GCM.open(box, using: key)
            case .chacha20IetfPoly1305:
                guard let nonceBox = try? ChaChaPoly.Nonce(data: nonce) else {
                    throw TouchFlowError.protocolError("shadowsocks: invalid ChaChaPoly nonce")
                }
                let box = try ChaChaPoly.SealedBox(nonce: nonceBox, ciphertext: body, tag: tag)
                return try ChaChaPoly.open(box, using: key)
            }
        } catch let error as TouchFlowError {
            throw error
        } catch {
            throw TouchFlowError.protocolError("shadowsocks: AEAD open failed (\(error))")
        }
    }
}

// MARK: - Key derivation

public enum ShadowsocksAEAD {
    /// Legacy `EVP_BytesToKey` MD5 chain used by every shadowsocks implementation.
    public static func masterKey(password: String, keyLength: Int = 32) -> Data {
        let passwordBytes = Data(password.utf8)
        var key = Data()
        var previous = Data()
        while key.count < keyLength {
            var input = previous
            input.append(passwordBytes)
            previous = Data(Insecure.MD5.hash(data: input))
            key.append(previous)
        }
        return key.prefix(keyLength)
    }

    /// HKDF-SHA1 with the salt as HKDF salt and the literal info string `ss-subkey`.
    public static func subkey(masterKey: Data, salt: Data, keyLength: Int = 32) -> Data {
        let inputKey = SymmetricKey(data: masterKey)
        let derived = HKDF<Insecure.SHA1>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: Data("ss-subkey".utf8),
            outputByteCount: keyLength
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    /// Convenience: full per-connection key material from a password and salt.
    public static func sessionKey(password: String, salt: Data, cipher: ShadowsocksCipher) -> Data {
        let master = masterKey(password: password, keyLength: cipher.keyLength)
        return subkey(masterKey: master, salt: salt, keyLength: cipher.keyLength)
    }

    /// Little-endian +1 over a 12-byte nonce.
    public static func incrementNonce(_ nonce: inout Data) {
        guard nonce.count == 12 else { return }
        for index in 0..<nonce.count {
            nonce[index] = nonce[index] &+ 1
            if nonce[index] != 0 { return }
        }
    }

    /// Encrypts `plaintext` as a full SIP004 stream: salt + (len | tag)(data | tag)*.
    public static func encryptStream(_ plaintext: Data, password: String, cipher: ShadowsocksCipher, salt: Data? = nil) throws -> Data {
        let saltBytes = salt ?? DataUtil.randomBytes(cipher.saltLength)
        let keyData = sessionKey(password: password, salt: saltBytes, cipher: cipher)
        let key = SymmetricKey(data: keyData)
        var nonce = Data(repeating: 0, count: 12)
        var out = saltBytes

        var offset = 0
        while offset < plaintext.count {
            let chunkSize = min(ShadowsocksCipher.maxChunk, plaintext.count - offset)
            let chunk = plaintext.subdata(in: offset..<(offset + chunkSize))
            let length = Data([UInt8((chunkSize >> 8) & 0xFF), UInt8(chunkSize & 0xFF)])
            out.append(try cipher.seal(length, key: key, nonce: nonce))
            incrementNonce(&nonce)
            out.append(try cipher.seal(chunk, key: key, nonce: nonce))
            incrementNonce(&nonce)
            offset += chunkSize
        }
        return out
    }

    /// Decrypts a full SIP004 stream produced by `encryptStream`.
    public static func decryptStream(_ packet: Data, password: String, cipher: ShadowsocksCipher) throws -> Data {
        guard packet.count >= cipher.saltLength else {
            throw TouchFlowError.protocolError("shadowsocks: stream shorter than salt")
        }
        let salt = packet.prefix(cipher.saltLength)
        let keyData = sessionKey(password: password, salt: salt, cipher: cipher)
        let key = SymmetricKey(data: keyData)
        var nonce = Data(repeating: 0, count: 12)
        var offset = cipher.saltLength
        var out = Data()
        let tag = cipher.tagLength

        while offset < packet.count {
            guard offset + 2 + tag <= packet.count else {
                throw TouchFlowError.protocolError("shadowsocks: truncated length block")
            }
            let lengthBlock = packet.subdata(in: offset..<(offset + 2 + tag))
            let lengthData = try cipher.open(lengthBlock, key: key, nonce: nonce)
            incrementNonce(&nonce)
            guard lengthData.count == 2 else {
                throw TouchFlowError.protocolError("shadowsocks: bad length block")
            }
            let bytes = Array(lengthData)
            let length = Int(bytes[0]) << 8 | Int(bytes[1])
            guard length <= ShadowsocksCipher.maxChunk else {
                throw TouchFlowError.protocolError("shadowsocks: chunk length \(length) exceeds limit")
            }
            offset += 2 + tag
            guard offset + length + tag <= packet.count else {
                throw TouchFlowError.protocolError("shadowsocks: truncated payload block")
            }
            let payloadBlock = packet.subdata(in: offset..<(offset + length + tag))
            let payload = try cipher.open(payloadBlock, key: key, nonce: nonce)
            incrementNonce(&nonce)
            offset += length + tag
            out.append(payload)
        }
        return out
    }
}

// MARK: - Encrypted stream

/// ByteStream that speaks the shadowsocks AEAD TCP framing over a raw socket.
public final class ShadowsocksStream: ByteStream, WriteHalfClosable, @unchecked Sendable {
    public let cipher: ShadowsocksCipher
    private let base: ByteStream
    private let key: SymmetricKey
    private let salt: Data
    private var nonce = Data(repeating: 0, count: 12)
    private var saltWritten = false
    private var rawBuffer = Data()
    private var plainBuffer = Data()
    private let lock = NSLock()

    public init(base: ByteStream, password: String, cipher: ShadowsocksCipher) {
        self.base = base
        self.cipher = cipher
        self.salt = DataUtil.randomBytes(cipher.saltLength)
        let keyData = ShadowsocksAEAD.sessionKey(password: password, salt: salt, cipher: cipher)
        self.key = SymmetricKey(data: keyData)
    }

    public var remoteDescription: String { "shadowsocks(\(cipher.rawValue))->\(base.remoteDescription)" }
    public var bytesRead: Int { base.bytesRead }
    public var bytesWritten: Int { base.bytesWritten }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        if !saltWritten {
            saltWritten = true
            try await base.write(salt)
        }
        var offset = 0
        while offset < data.count {
            let size = min(ShadowsocksCipher.maxChunk, data.count - offset)
            let chunk = data.subdata(in: offset..<(offset + size))
            let length = Data([UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)])
            let sealedLength = try cipher.seal(length, key: key, nonce: nonce)
            ShadowsocksAEAD.incrementNonce(&nonce)
            let sealedChunk = try cipher.seal(chunk, key: key, nonce: nonce)
            ShadowsocksAEAD.incrementNonce(&nonce)
            var frame = sealedLength
            frame.append(sealedChunk)
            try await base.write(frame)
            offset += size
        }
    }

    public func read(maxLength: Int) async throws -> Data? {
        if !plainBuffer.isEmpty {
            return takePlain(maxLength)
        }
        while true {
            if plainBuffer.isEmpty {
                try await readOneChunk()
            }
            if !plainBuffer.isEmpty {
                return takePlain(maxLength)
            }
            return nil
        }
    }

    public func closeWrite() {
        if let half = base as? WriteHalfClosable { half.closeWrite() } else { base.close() }
    }

    public func close() {
        base.close()
    }

    // MARK: Internals

    private func takePlain(_ maxLength: Int) -> Data {
        let size = min(max(maxLength, 1), plainBuffer.count)
        let out = plainBuffer.prefix(size)
        plainBuffer.removeFirst(size)
        return Data(out)
    }

    private func fillRaw(_ needed: Int) async throws -> Bool {
        while rawBuffer.count < needed {
            let want = max(needed - rawBuffer.count, 4096)
            guard let chunk = try await base.read(maxLength: want) else { return false }
            if chunk.isEmpty { continue }
            rawBuffer.append(chunk)
        }
        return true
    }

    private func readOneChunk() async throws {
        let tag = cipher.tagLength
        guard try await fillRaw(2 + tag) else {
            if !rawBuffer.isEmpty {
                throw TouchFlowError.protocolError("shadowsocks: truncated length block at EOF")
            }
            return
        }
        let lengthBlock = rawBuffer.prefix(2 + tag)
        rawBuffer.removeFirst(2 + tag)
        let lengthData = try cipher.open(Data(lengthBlock), key: key, nonce: nonce)
        ShadowsocksAEAD.incrementNonce(&nonce)
        guard lengthData.count == 2 else {
            throw TouchFlowError.protocolError("shadowsocks: malformed length block")
        }
        let bytes = Array(lengthData)
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        guard length > 0, length <= ShadowsocksCipher.maxChunk else {
            throw TouchFlowError.protocolError("shadowsocks: invalid chunk length \(length)")
        }
        guard try await fillRaw(length + tag) else {
            throw TouchFlowError.protocolError("shadowsocks: truncated payload block at EOF")
        }
        let payloadBlock = rawBuffer.prefix(length + tag)
        rawBuffer.removeFirst(length + tag)
        let payload = try cipher.open(Data(payloadBlock), key: key, nonce: nonce)
        ShadowsocksAEAD.incrementNonce(&nonce)
        plainBuffer.append(payload)
    }
}
