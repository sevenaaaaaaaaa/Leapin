import CryptoKit
import Foundation
import XCTest
@testable import TouchFlowCore
@testable import TouchFlowNet

/// Shadowsocks AEAD (SIP004) tests. The key-derivation vectors below were
/// produced by an independent Python implementation of EVP_BytesToKey(MD5) and
/// HKDF-SHA1, so they cross-check CryptoKit rather than restating it.
final class ShadowsocksTests: XCTestCase {
    // password "test-password", keyLength 32
    private let masterKeyVector = "dfb450efddbb5387197c84460623675b69f2cebcd8ef520a3dfddef7c3d540b2"
    // HKDF-SHA1(masterKey, salt: 0x00..0x1f, info: "ss-subkey", 32)
    private let subkeyVector = "7b6ca12d45ef79467432717aaa6a6ae6e1dd046a505fb2ebaaac602210919595"
    // password "password", keyLength 32
    private let passwordKeyVector = "5f4dcc3b5aa765d61d8327deb882cf992b95990a9151374abd8ff8c5a7a0fe08"

    func testMasterKeyMatchesEVPBytesToKeyVector() {
        let key = ShadowsocksAEAD.masterKey(password: "test-password", keyLength: 32)
        XCTAssertEqual(HexCoding.encode(key), masterKeyVector)
        let other = ShadowsocksAEAD.masterKey(password: "password", keyLength: 32)
        XCTAssertEqual(HexCoding.encode(other), passwordKeyVector)
    }

    func testSubkeyMatchesHKDFVector() {
        let master = ShadowsocksAEAD.masterKey(password: "test-password", keyLength: 32)
        let salt = Data((0..<32).map { UInt8($0) })
        let subkey = ShadowsocksAEAD.subkey(masterKey: master, salt: salt, keyLength: 32)
        XCTAssertEqual(HexCoding.encode(subkey), subkeyVector)
    }

    func testSessionKeyMatchesSubkeyVector() {
        let salt = Data((0..<32).map { UInt8($0) })
        let session = ShadowsocksAEAD.sessionKey(password: "test-password",
                                                salt: salt,
                                                cipher: .aes256gcm)
        XCTAssertEqual(HexCoding.encode(session), subkeyVector)
    }

    func testCipherNameNormalisation() {
        XCTAssertEqual(ShadowsocksCipher("aes-256-gcm"), .aes256gcm)
        XCTAssertEqual(ShadowsocksCipher("AEAD_AES_256_GCM"), .aes256gcm)
        XCTAssertEqual(ShadowsocksCipher("aes_256_gcm"), .aes256gcm)
        XCTAssertEqual(ShadowsocksCipher("chacha20-ietf-poly1305"), .chacha20IetfPoly1305)
        XCTAssertEqual(ShadowsocksCipher("chacha20-poly1305"), .chacha20IetfPoly1305)
        XCTAssertNil(ShadowsocksCipher("rc4-md5"))
        XCTAssertEqual(ShadowsocksCipher.aes256gcm.keyLength, 32)
        XCTAssertEqual(ShadowsocksCipher.maxChunk, 0x3FFF)
    }

    func testNonceIncrementIsLittleEndian() {
        var nonce = Data(repeating: 0, count: 12)
        ShadowsocksAEAD.incrementNonce(&nonce)
        XCTAssertEqual(Array(nonce), [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])

        nonce = Data([0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        ShadowsocksAEAD.incrementNonce(&nonce)
        XCTAssertEqual(Array(nonce), [0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0])

        nonce = Data(repeating: 0, count: 5) // wrong size: untouched
        ShadowsocksAEAD.incrementNonce(&nonce)
        XCTAssertEqual(Array(nonce), [0, 0, 0, 0, 0])
    }

    func testAEADSealOpenRoundTripAndTamperDetection() throws {
        for cipher in ShadowsocksCipher.allCases {
            let key = SymmetricKey(data: Data(repeating: 7, count: cipher.keyLength))
            let nonce = Data(repeating: 0, count: 12)
            let message = Data("aead round trip".utf8)
            let sealed = try cipher.seal(message, key: key, nonce: nonce)
            XCTAssertEqual(sealed.count, message.count + cipher.tagLength)
            XCTAssertEqual(try cipher.open(sealed, key: key, nonce: nonce), message)

            var tampered = sealed
            tampered[tampered.count - 1] ^= 0xFF
            XCTAssertThrowsError(try cipher.open(tampered, key: key, nonce: nonce))
        }
    }

    func testStreamFormatIsSaltThenLengthThenPayload() throws {
        for cipher in ShadowsocksCipher.allCases {
            let salt = Data(repeating: 0xAA, count: cipher.saltLength)
            let plaintext = Data("hello shadowsocks".utf8)
            let framed = try ShadowsocksAEAD.encryptStream(plaintext,
                                                          password: "pw",
                                                          cipher: cipher,
                                                          salt: salt)
            // salt + sealed(2-byte length) + sealed(payload)
            let expected = cipher.saltLength + (2 + cipher.tagLength) + (plaintext.count + cipher.tagLength)
            XCTAssertEqual(framed.count, expected)
            XCTAssertEqual(framed.prefix(cipher.saltLength), salt)

            let sealedLength = try cipher.seal(Data([0x00, UInt8(plaintext.count)]),
                                              key: SymmetricKey(data: ShadowsocksAEAD.sessionKey(password: "pw",
                                                                                                salt: salt,
                                                                                                cipher: cipher)),
                                              nonce: Data(repeating: 0, count: 12))
            XCTAssertEqual(framed.subdata(in: cipher.saltLength..<(cipher.saltLength + sealedLength.count)),
                           sealedLength)

            XCTAssertEqual(try ShadowsocksAEAD.decryptStream(framed, password: "pw", cipher: cipher), plaintext)
        }
    }

    func testStreamRoundTripAcrossChunkBoundary() throws {
        for cipher in ShadowsocksCipher.allCases {
            // 100_000 bytes forces more than one 0x3FFF chunk.
            let payload = Data((0..<100_000).map { UInt8($0 % 251) })
            let salt = Data(repeating: 0x11, count: cipher.saltLength)
            let framed = try ShadowsocksAEAD.encryptStream(payload,
                                                          password: "pass phrase",
                                                          cipher: cipher,
                                                          salt: salt)
            let chunks = (payload.count + ShadowsocksCipher.maxChunk - 1) / ShadowsocksCipher.maxChunk
            let expected = cipher.saltLength + chunks * (2 + cipher.tagLength) + payload.count + chunks * cipher.tagLength
            XCTAssertEqual(framed.count, expected)
            XCTAssertEqual(try ShadowsocksAEAD.decryptStream(framed, password: "pass phrase", cipher: cipher), payload)
        }
    }

    func testStreamEmptyAndBoundarySizes() throws {
        for size in [0, 1, 0x3FFF, 0x4000] {
            let payload = Data(repeating: 0x5A, count: size)
            let salt = Data(repeating: 0x22, count: 32)
            let framed = try ShadowsocksAEAD.encryptStream(payload,
                                                          password: "pw",
                                                          cipher: .chacha20IetfPoly1305,
                                                          salt: salt)
            XCTAssertEqual(try ShadowsocksAEAD.decryptStream(framed,
                                                            password: "pw",
                                                            cipher: .chacha20IetfPoly1305),
                           payload,
                           "round trip failed for \(size) bytes")
        }
    }

    func testDecryptRejectsTruncatedStream() throws {
        let payload = Data(repeating: 0x01, count: 64)
        let salt = Data(repeating: 0x33, count: 32)
        let framed = try ShadowsocksAEAD.encryptStream(payload, password: "pw", cipher: .aes256gcm, salt: salt)
        XCTAssertThrowsError(try ShadowsocksAEAD.decryptStream(framed.prefix(40),
                                                               password: "pw",
                                                               cipher: .aes256gcm))
    }

    func testDecryptWithWrongPasswordFails() throws {
        let salt = Data(repeating: 0x44, count: 32)
        let framed = try ShadowsocksAEAD.encryptStream(Data("secret".utf8),
                                                       password: "right",
                                                       cipher: .aes256gcm,
                                                       salt: salt)
        XCTAssertThrowsError(try ShadowsocksAEAD.decryptStream(framed, password: "wrong", cipher: .aes256gcm))
    }
}
