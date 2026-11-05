import Foundation
import AppKit
import TouchFlowCore

/// Finder-first SMB mounting plus a scripted `mount_smbfs` fallback.
public enum NASMounter {
    static let mountSMBBinary = "/sbin/mount_smbfs"
    static let umountBinary = "/sbin/umount"
    static let mountBinary = "/sbin/mount"

    /// Hands the URL to Finder/LaunchServices, which performs authentication via
    /// Keychain and the system SMB stack. Safest option: no credentials in argv.
    public static func openInFinder(host: String, share: String? = nil) throws {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard host.isEmpty == false else {
            throw TouchFlowError.invalidConfiguration("host is required")
        }
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host
        if let share, share.isEmpty == false {
            components.path = "/" + share
        }
        guard let url = components.url else {
            throw TouchFlowError.invalidConfiguration("cannot build smb:// URL for \(host)")
        }
        guard NSWorkspace.shared.open(url) else {
            throw TouchFlowError.connectionFailed("Finder refused to open \(url.absoluteString)")
        }
        TFLog.shared.info("integrations.nas", "opened \(url.absoluteString) in Finder")
    }

    /// Mounts `smb://host/share` under `~/Volumes/<share>` and returns the mount URL.
    ///
    /// Credentials never enter our own `Process.arguments` or the log: a 0600 shell
    /// helper is written to a private temp directory, the user/password travel via
    /// the child environment, and the helper is deleted in `defer`. The helper still
    /// expands the password into `mount_smbfs`'s own argv, which is the only way that
    /// tool accepts a password non-interactively; the exposure is limited to
    /// same-user processes for the duration of the mount and is documented in
    /// docs/integrations.md. Errors are redacted before they are surfaced.
    public static func mountSMB(host: String, share: String, user: String, password: String) throws -> URL {
        let host = host.trimmingCharacters(in: .whitespaces)
        let share = share.trimmingCharacters(in: .whitespaces)
        let user = user.trimmingCharacters(in: .whitespaces)
        guard host.isEmpty == false, share.isEmpty == false, user.isEmpty == false else {
            throw TouchFlowError.invalidConfiguration("host, share and user are required")
        }
        guard FileManager.default.isExecutableFile(atPath: mountSMBBinary) else {
            throw TouchFlowError.unsupported("\(mountSMBBinary) not found")
        }

        let mountPoint = try makeMountPoint(share: share)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("touchflow-smb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        // The helper only reads the credentials from its environment, our argv stays clean.
        let script = directory.appendingPathComponent("mount.sh")
        let body = """
        #!/bin/sh
        exec /sbin/mount_smbfs "//${TF_SMB_USER}:${TF_SMB_PASSWORD}@${1}/${2}" "${3}"
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
        } catch {
            throw TouchFlowError.invalidConfiguration("cannot create mount helper: \(error.localizedDescription)")
        }

        let environment = [
            "TF_SMB_USER": percentEncoded(user),
            "TF_SMB_PASSWORD": percentEncoded(password),
        ]
        let output: CommandOutput
        do {
            output = try CommandRunner.run(executable: script.path,
                                           arguments: [host, share, mountPoint.path],
                                           timeout: 20,
                                           environment: environment)
        } catch {
            throw error
        }

        if output.timedOut {
            throw TouchFlowError.timeout
        }
        guard output.status == 0 else {
            let detail = redact(output.tail(), secrets: [password, percentEncoded(password)])
            throw TouchFlowError.connectionFailed("mount_smbfs exited with \(output.status): \(detail)")
        }

        // Confirm the kernel actually registered the mount point.
        let listing = try? CommandRunner.run(executable: mountBinary, arguments: [], timeout: 10)
        if let listing, listing.stdout.contains(mountPoint.path) == false {
            throw TouchFlowError.connectionFailed("mount_smbfs reported success but \(mountPoint.path) is not mounted")
        }
        TFLog.shared.info("integrations.nas", "mounted \(host)/\(share) at \(mountPoint.path)")
        return mountPoint
    }

    /// Unmounts a mount point previously returned by `mountSMB`.
    public static func unmount(_ url: URL) throws {
        let path = url.path
        guard path.isEmpty == false else {
            throw TouchFlowError.invalidConfiguration("empty mount point")
        }
        try CommandRunner.runChecked(executable: umountBinary, arguments: [path], timeout: 20)
        TFLog.shared.info("integrations.nas", "unmounted \(path)")
    }

    /// Reveals an already mounted volume in Finder.
    public static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Helpers

    static func makeMountPoint(share: String) throws -> URL {
        // The share name becomes a path component under ~/Volumes, so anything that
        // could escape that directory ("", ".", "..", "a/../b") must be rejected
        // before we create folders or hand the path to mount_smbfs.
        let trimmed = share.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw TouchFlowError.invalidConfiguration("share name is required")
        }
        guard trimmed != ".", trimmed != ".." else {
            throw TouchFlowError.invalidConfiguration("invalid share name \"\(share)\"")
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard components.contains("..") == false else {
            throw TouchFlowError.invalidConfiguration("share name \"\(share)\" must not contain \"..\"")
        }
        let safeShare = trimmed.replacingOccurrences(of: "/", with: "-")
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Volumes", isDirectory: true)
            .standardizedFileURL
        let mountPoint = base.appendingPathComponent(safeShare, isDirectory: true).standardizedFileURL
        // Belt and braces: the resolved path must stay directly under ~/Volumes.
        guard mountPoint.deletingLastPathComponent().path == base.path else {
            throw TouchFlowError.invalidConfiguration("share name \"\(share)\" escapes the mount root")
        }
        do {
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true,
                                                    attributes: nil)
        } catch {
            throw TouchFlowError.invalidConfiguration("cannot create mount point \(mountPoint.path): \(error.localizedDescription)")
        }
        return mountPoint
    }

    /// Percent-encodes user/password for the smb:// URL used by mount_smbfs.
    static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func redact(_ text: String, secrets: [String]) -> String {
        var output = text
        for secret in secrets where secret.isEmpty == false {
            output = output.replacingOccurrences(of: secret, with: "***")
        }
        return output
    }
}
