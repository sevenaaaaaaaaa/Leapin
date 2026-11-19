import CryptoKit
import Darwin
import Foundation
import Network
import Security
import LeapinCore

/// One in-progress leaf generation that other handshakes for the same host wait on.
/// `openssl` runs outside the cache lock, so this is what keeps two concurrent
/// handshakes for one host from minting two certificates.
private final class IdentitySlot: @unchecked Sendable {
    // A condition, not a semaphore: every waiter for this host must observe the
    // result, and a semaphore signal is consumed by exactly one of them.
    private let condition = NSCondition()
    private var stored: Result<sec_identity_t, Error>?

    func finish(_ result: Result<sec_identity_t, Error>) {
        condition.lock()
        stored = result
        condition.broadcast()
        condition.unlock()
    }

    func wait() -> Result<sec_identity_t, Error> {
        condition.lock()
        while stored == nil { condition.wait() }
        let result = stored ?? .failure(LeapinError.connectionFailed("leaf generation lost its result"))
        condition.unlock()
        return result
    }
}

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
    /// Leaf generations in flight, keyed by host. Concurrent handshakes for one
    /// host share a single `openssl` run instead of each minting its own cert.
    private var pendingIdentities: [String: IdentitySlot] = [:]
    /// Leaf certificate runs this process really performed (test aid).
    private var generatedLeaves = 0

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

        // The CA key can mint a certificate trusted by this machine for any host,
        // so neither the key nor the directory may be readable by other accounts.
        restrictPermissions()
    }

    /// Tightens the modes of the CA material. A mode we cannot set is never fatal:
    /// HTTPS interception keeps working, and the next launch tries again.
    private func restrictPermissions() {
        Self.restrict(directory, mode: 0o700)
        Self.restrict(leafRoot, mode: 0o700)
        Self.restrict(caPrivateKeyPath, mode: 0o600)
        Self.restrict(configPath, mode: 0o600)
        Self.restrict(serialPath, mode: 0o600)
    }

    private static func restrict(_ url: URL, mode: Int) {
        try? FileManager.default.setAttributes([.posixPermissions: mode],
                                               ofItemAtPath: url.path)
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
    ///
    /// Minting a leaf runs two RSA-2048 key generations, so it must never happen
    /// under the cache lock: one slow host would otherwise queue every other
    /// host's handshake behind it. The lock only claims the work; concurrent
    /// callers for the same host wait on that host's slot and share the result.
    public func identity(for host: String) throws -> sec_identity_t {
        let key = host.lowercased()
        if let cached = lock.withLock({ identityCache[key] }) {
            return cached
        }

        let (slot, isOwner) = lock.withLock { () -> (IdentitySlot, Bool) in
            if let running = pendingIdentities[key] { return (running, false) }
            let fresh = IdentitySlot()
            pendingIdentities[key] = fresh
            return (fresh, true)
        }
        // A handshake for a host that is already being minted waits for that run
        // instead of starting a second one.
        guard isOwner else { return try slot.wait().get() }

        let outcome: Result<sec_identity_t, Error>
        do {
            let created = try loadOrCreateIdentity(for: key)
            lock.withLock {
                identityCache[key] = created
                generatedLeaves += 1
            }
            outcome = .success(created)
        } catch {
            outcome = .failure(error)
        }
        slot.finish(outcome)
        lock.withLock {
            if pendingIdentities[key] === slot { pendingIdentities.removeValue(forKey: key) }
        }
        return try outcome.get()
    }

    /// Leaf certificates this process really generated (imported cache hits excluded).
    var leafGenerationCount: Int { lock.withLock { generatedLeaves } }

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
            Self.restrict(dir, mode: 0o700)
            Self.restrict(dir.appendingPathComponent("leaf-private.pem"), mode: 0o600)
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
        let result = try runProcess(executable: opensslPath, arguments: arguments,
                                    workingDirectory: workingDirectory)
        guard result.status == 0 else {
            let message = result.stderrText.isEmpty
                ? "exit \(result.status)" : result.stderrText
            throw LeapinError.connectionFailed(
                "openssl \(arguments.first ?? "") failed: \(message)")
        }
        return result.stdoutText
    }

    /// Output of one helper process run to completion, or killed at the deadline.
    struct ProcessResult: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data

        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        var stderrText: String {
            String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Runs a helper process with both pipes drained concurrently and a hard deadline.
    ///
    /// Both readers start before the child is asked to run, and each drains its own
    /// pipe on its own thread. Reading stdout to EOF first — the previous
    /// implementation — blocks forever the moment a child fills the 64 KB stderr
    /// buffer, and waitUntilExit() then never returns. A deadline keeps a wedged
    /// openssl from holding the handshake (and the CA) up indefinitely.
    @discardableResult
    static func runProcess(executable: String,
                           arguments: [String],
                           workingDirectory: URL? = nil,
                           timeout: TimeInterval = 30,
                           environment: [String: String]? = nil) throws -> ProcessResult {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment { merged[key] = value }
            process.environment = merged
        }
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let outBox = ByteBox()
        let errBox = ByteBox()
        let readers = DispatchGroup()
        for (pipe, box) in [(stdoutPipe, outBox), (stderrPipe, errBox)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                box.set(pipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }
        }

        // Arm the exit signal before running, or a fast child can finish before the
        // handler exists and the wait below would never be released.
        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSignal.signal() }

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            _ = readers.wait(timeout: .now() + 1)
            throw LeapinError.connectionFailed(
                "cannot launch \((executable as NSString).lastPathComponent): \(error.localizedDescription)")
        }
        // Our own copies of the write ends would otherwise hold the pipes open.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        if exitSignal.wait(timeout: .now() + max(0.5, timeout)) == .timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 2)
            }
            _ = readers.wait(timeout: .now() + 2)
            let tail = String(decoding: errBox.get(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            LPLog.shared.error("net.ca", "\((executable as NSString).lastPathComponent) timed out after \(timeout)s")
            throw LeapinError.connectionFailed(
                "openssl timed out after \(timeout)s\(tail.isEmpty ? "" : ": \(tail)")")
        }

        _ = readers.wait(timeout: .now() + 2)
        // Reading terminationStatus while the child is alive raises an Objective-C
        // exception Swift cannot catch; a child that outlived SIGKILL is a failure.
        guard !process.isRunning else {
            throw LeapinError.connectionFailed("openssl did not exit after SIGKILL")
        }
        return ProcessResult(status: process.terminationStatus,
                             stdout: outBox.get(), stderr: errBox.get())
        #else
        // iOS cannot spawn helper processes, so on-device CA generation is unavailable.
        // The mobile client never decrypts TLS; it only talks to the desktop control plane.
        _ = executable
        _ = arguments
        _ = workingDirectory
        _ = timeout
        _ = environment
        throw LeapinError.connectionFailed("certificate generation requires the macOS CLI (openssl is not spawnable on iOS)")
        #endif
    }
}

/// Thread-safe byte accumulator for the two pipe reader threads.
private final class ByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.withLock { data = value }
    }

    func get() -> Data {
        lock.withLock { data }
    }
}
