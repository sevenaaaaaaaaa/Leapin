import CryptoKit
import Foundation
import Network
import Security
import LeapinCore

/// Generates (and caches) a root CA plus per-host leaf certificates with
/// `/usr/bin/openssl`, then hands back `sec_identity_t` values for TLS
/// termination during MITM.
///
/// All private material stays inside `directory`; the PKCS#12 export password is
/// a random string kept only in memory for the duration of the import.
public final class CertificateAuthority: @unchecked Sendable {
    public static let opensslPath = "/usr/bin/openssl"

    public let directory: URL

    private let caCertificatePath: URL
    private let caPrivateKeyPath: URL
    private let serialPath: URL
    private let configPath: URL
    private let leafRoot: URL
    private let passwordLock = NSLock()
    private var cachedP12Password: String?
    private let lock = NSLock()
    private var identityCache: [String: sec_identity_t] = [:]

    /// PEM-encoded root certificate. UI installs this into the trust store.
    public var caCertificateURL: URL { caCertificatePath }

    public init(directory: URL) throws {
        self.directory = directory
        self.caCertificatePath = directory.appendingPathComponent("ca.pem")
        self.caPrivateKeyPath = directory.appendingPathComponent("ca-private.pem")
        self.serialPath = directory.appendingPathComponent("ca.srl")
        self.configPath = directory.appendingPathComponent("ca.cnf")
        self.leafRoot = directory.appendingPathComponent("leaves", isDirectory: true)

        guard FileManager.default.isExecutableFile(atPath: Self.opensslPath) else {
            throw LeapinError.invalidConfiguration(
                "certificate authority requires \(Self.opensslPath), which is missing")
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: leafRoot, withIntermediateDirectories: true)
        } catch {
            throw LeapinError.invalidConfiguration(
                "cannot create certificate directory \(directory.path): \(error.localizedDescription)")
        }

        let hasCA = FileManager.default.fileExists(atPath: caCertificatePath.path)
            && FileManager.default.fileExists(atPath: caPrivateKeyPath.path)
        if !hasCA {
            try generateRootCA()
        } else {
            LPLog.shared.debug("net.ca", "reusing root CA at \(caCertificatePath.path)")
        }
    }

    // MARK: - Public API

    /// PKCS#12 export password. Derived from the CA private key so cached leaf
    /// bundles stay importable across launches, while never being written to disk
    /// on its own (the p12 files carry the key material, the password does not).
    private var p12Password: String {
        if let cached = passwordLock.withLock({ cachedP12Password }) { return cached }
        let material = (try? Data(contentsOf: caPrivateKeyPath)) ?? Data()
        let digest = SHA256.hash(data: material)
        let password = "leapin-" + digest.map { String(format: "%02x", $0) }.joined()
        passwordLock.withLock { cachedP12Password = password }
        return password
    }

    /// Returns a TLS server identity (certificate + private key) for `host`.
    public func identity(for host: String) throws -> sec_identity_t {
        let key = host.lowercased()
        if let cached = lock.withLock({ identityCache[key] }) {
            return cached
        }
        return try lock.withLock { () -> sec_identity_t in
            if let cached = identityCache[key] { return cached }
            let created = try loadOrCreateIdentity(for: key)
            identityCache[key] = created
            return created
        }
    }

    public func leafCertificateURL(for host: String) -> URL {
        leafDirectory(for: host).appendingPathComponent("leaf.pem")
    }

    // MARK: - Root CA

    private func generateRootCA() throws {
        let config = """
        [req]
        distinguished_name = dn
        prompt = no
        x509_extensions = v3_ca

        [dn]
        CN = Leapin Root CA
        O = Leapin

        [v3_ca]
        basicConstraints = critical,CA:TRUE,pathlen:0
        keyUsage = critical,keyCertSign,cRLSign
        subjectKeyIdentifier = hash

        """
        try write(Data(config.utf8), to: configPath)
        LPLog.shared.info("net.ca", "generating root CA in \(directory.path)")
        try Self.run([
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650", "-nodes",
            "-keyout", caPrivateKeyPath.path,
            "-out", caCertificatePath.path,
            "-config", configPath.path,
        ], workingDirectory: directory)
        guard FileManager.default.fileExists(atPath: caCertificatePath.path) else {
            throw LeapinError.connectionFailed("openssl did not produce \(caCertificatePath.path)")
        }
    }

    // MARK: - Leaf certificates

    private func leafDirectory(for host: String) -> URL {
        let safe = host.map { character -> Character in
            if character.isLetter || character.isNumber || character == "." || character == "-" {
                return character
            }
            return "_"
        }
        return leafRoot.appendingPathComponent(String(safe), isDirectory: true)
    }

    private func loadOrCreateIdentity(for host: String) throws -> sec_identity_t {
        let dir = leafDirectory(for: host)
        let p12 = dir.appendingPathComponent("leaf.p12")
        let cert = dir.appendingPathComponent("leaf.pem")

        if FileManager.default.fileExists(atPath: p12.path),
           let identity = try? importIdentity(p12: p12) {
            return identity
        }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try generateLeaf(for: host, in: dir)
            if FileManager.default.fileExists(atPath: p12.path) {
                _ = try? FileManager.default.removeItem(at: p12)
            }
            try Self.run([
                "pkcs12", "-export", "-out", p12.path,
                "-inkey", dir.appendingPathComponent("leaf-private.pem").path,
                "-in", cert.path,
                "-certfile", caCertificatePath.path,
                "-passout", "pass:\(p12Password)",
            ], workingDirectory: dir)
            return try importIdentity(p12: p12)
        } catch {
            LPLog.shared.error("net.ca", "leaf generation for \(host) failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func generateLeaf(for host: String, in dir: URL) throws {
        let isIP = NetAddress.isIPLiteral(host)
        let altName = isIP ? "IP.1 = \(host)" : "DNS.1 = \(host)"
        let config = """
        [req]
        distinguished_name = dn
        prompt = no

        [dn]
        CN = \(host)
        O = Leapin

        [leaf]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = @alt_names

        [alt_names]
        \(altName)

        """
        let configURL = dir.appendingPathComponent("leaf.cnf")
        try write(Data(config.utf8), to: configURL)

        let privateKey = dir.appendingPathComponent("leaf-private.pem")
        let csr = dir.appendingPathComponent("leaf.csr")
        let cert = dir.appendingPathComponent("leaf.pem")

        try Self.run([
            "req", "-new", "-newkey", "rsa:2048", "-sha256", "-nodes",
            "-keyout", privateKey.path, "-out", csr.path,
            "-config", configURL.path,
        ], workingDirectory: dir)

        try Self.run([
            "x509", "-req", "-in", csr.path, "-sha256", "-days", "825",
            "-CA", caCertificatePath.path,
            "-CAkey", caPrivateKeyPath.path,
            "-CAserial", serialPath.path,
            "-CAcreateserial",
            "-extfile", configURL.path,
            "-extensions", "leaf",
            "-out", cert.path,
        ], workingDirectory: dir)
    }

    private func importIdentity(p12: URL) throws -> sec_identity_t {
        let data: Data
        do {
            data = try Data(contentsOf: p12)
        } catch {
            throw LeapinError.connectionFailed("cannot read \(p12.path): \(error.localizedDescription)")
        }
        let options: [String: Any] = [kSecImportExportPassphrase as String: p12Password]
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess else {
            throw LeapinError.connectionFailed("SecPKCS12Import failed for \(p12.lastPathComponent) (OSStatus \(status))")
        }
        let items = rawItems as? [[String: Any]] ?? []
        for item in items {
            guard let raw = item[kSecImportItemIdentity as String] else { continue }
            // A conditional downcast to a CF type is rejected by the compiler, so the
            // type id is verified explicitly before the (guarded) forced cast.
            guard CFGetTypeID(raw as CFTypeRef) == SecIdentityGetTypeID() else { continue }
            let identity = raw as! SecIdentity
            if let secIdentity = sec_identity_create(identity) {
                return secIdentity
            }
        }
        throw LeapinError.connectionFailed("PKCS#12 archive \(p12.lastPathComponent) has no usable identity")
    }

    // MARK: - Helpers

    private func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw LeapinError.connectionFailed("cannot write \(url.path): \(error.localizedDescription)")
        }
    }

    @discardableResult
    private static func run(_ arguments: [String], workingDirectory: URL) throws -> String {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opensslPath)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw LeapinError.connectionFailed("cannot launch openssl: \(error.localizedDescription)")
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let message = stderr.isEmpty ? "exit \(process.terminationStatus)" : stderr
            throw LeapinError.connectionFailed(
                "openssl \(arguments.first ?? "") failed: \(message)")
        }
        return String(decoding: outData, as: UTF8.self)
        #else
        // iOS cannot spawn helper processes, so on-device CA generation is unavailable.
        // The mobile client never decrypts TLS; it only talks to the desktop control plane.
        _ = arguments
        _ = workingDirectory
        throw LeapinError.connectionFailed("certificate generation requires the macOS CLI (openssl is not spawnable on iOS)")
        #endif
    }
}
