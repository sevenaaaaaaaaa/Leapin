import Foundation
import Security
import TouchFlowCore

// MARK: - Panel token

/// Token that authorises the read-only LAN panel. It grants *view* access
/// only (no config content, no actions) and can be rotated without touching
/// the device identity used for signed sync requests.
public enum PanelTokenStore {
    public static let fileName = "panel-token"

    public static func url(root: URL) -> URL {
        root.appendingPathComponent(fileName)
    }

    /// Reads the token, creating a 32-byte one on first use. The directory is
    /// 0700 and the file 0600; writing is atomic.
    public static func token(root: URL) throws -> String {
        let file = url(root: root)
        if let data = try? Data(contentsOf: file),
           let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count == 64 && trimmed.allSatisfy({ $0.isHexDigit }) {
                return trimmed.lowercased()
            }
        }
        return try rotate(root: root)
    }

    @discardableResult
    public static func rotate(root: URL) throws -> String {
        let directory = root
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SyncError.transport("panel token generation failed (OSStatus \(status))")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let file = url(root: directory)
        let temporary = directory.appendingPathComponent(".\(fileName).tmp")
        try Data(token.utf8).write(to: temporary, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return token
    }
}

// MARK: - Snapshot

/// Everything the read-only panel shows. Deliberately metadata only: no rule
/// values, no outbound credentials, no profile body. A browser on the LAN is
/// the weakest link in the trust chain, so it must not be able to read config.
public struct SyncPanelSnapshot: Codable, Sendable, Hashable {
    public var device: SyncDevice
    public var generatedAtMs: Int64
    public var versions: [ProfileVersion]
    public var pointers: [String: ActivePointer]
    public var effective: String?
    public var applied: String?
    public var peers: [SyncPeer]
    public var readOnly: Bool
    public var notice: String

    public init(device: SyncDevice, generatedAtMs: Int64,
                versions: [ProfileVersion], pointers: [String: ActivePointer],
                effective: String?, applied: String?, peers: [SyncPeer]) {
        self.device = device
        self.generatedAtMs = generatedAtMs
        self.versions = versions
        self.pointers = pointers
        self.effective = effective
        self.applied = applied
        self.peers = peers
        self.readOnly = true
        self.notice = "只读面板：仅显示版本元数据，不含规则与凭据；关闭同步服务即失效。"
    }
}

// MARK: - HTML

public enum SyncPanelHTML {
    /// Standalone page: inline CSS, no scripts, no external assets, and every
    /// interpolated value HTML-escaped.
    public static func render(_ snapshot: SyncPanelSnapshot) -> String {
        let generated = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(snapshot.generatedAtMs) / 1000))
        let effective = snapshot.effective.map { short($0) } ?? "无"
        let applied = snapshot.applied.map { short($0) } ?? "无"

        let rows = snapshot.versions.map { version -> String in
            let marker = version.id == snapshot.effective ? "▶" : " "
            let origin = snapshot.pointers[version.originDevice]
            let pointer = origin?.version == version.id ? "●" : " "
            return """
            <tr><td class="mark">\(marker)</td><td class="mono">\(escape(short(version.id)))</td>            <td>\(escape(version.name))</td><td class="num">\(version.ruleCount)</td>            <td class="mono">\(escape(short(version.originDevice)))</td>            <td class="num">\(version.createdAtMs)</td><td class="mark">\(pointer)</td></tr>
            """
        }.joined()

        let peers = snapshot.peers.isEmpty
            ? "<p class=\"muted\">尚未配对其它设备。</p>"
            : snapshot.peers.map { peer in
                """
                <tr><td>\(escape(peer.device.name))</td>                <td class="mono">\(escape(peer.device.fingerprint))</td>                <td class="num">\(peer.lastSeenMs)</td></tr>
                """
            }.joined()

        let pointers = snapshot.pointers.sorted { $0.key < $1.key }.map { device, pointer in
            """
            <tr><td class="mono">\(escape(short(device)))</td>            <td class="mono">\(escape(short(pointer.version)))</td>            <td class="num">\(pointer.updatedAtMs)</td></tr>
            """
        }.joined()

        return """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="robots" content="noindex,nofollow">
        <title>TouchFlow · 只读面板</title>
        <style>
        :root{color-scheme:light dark}
        body{margin:0;padding:28px 20px 48px;font:14px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC",sans-serif;background:#f7f6f3;color:#1b1b1f}
        @media (prefers-color-scheme:dark){body{background:#151518;color:#ececf1}}
        main{max-width:820px;margin:0 auto}
        h1{font-size:20px;font-weight:600;margin:0 0 2px;letter-spacing:-.01em}
        h2{font-size:11px;font-weight:600;letter-spacing:.09em;text-transform:uppercase;color:#8a8a94;margin:30px 0 8px}
        .sub{color:#6f6f7a;font-size:12px;margin:0 0 24px}
        .card{border:1px solid rgba(0,0,0,.10);border-radius:10px;padding:14px 16px;background:rgba(255,255,255,.66)}
        @media (prefers-color-scheme:dark){.card{border-color:rgba(255,255,255,.14);background:rgba(255,255,255,.05)}}
        .kv{display:grid;grid-template-columns:130px 1fr;gap:6px 12px;font-size:13px}
        .kv div:nth-child(odd){color:#6f6f7a}
        table{width:100%;border-collapse:collapse;font-size:12px}
        th,td{text-align:left;padding:6px 8px;border-bottom:1px solid rgba(0,0,0,.08);vertical-align:top}
        @media (prefers-color-scheme:dark){th,td{border-color:rgba(255,255,255,.12)}}
        th{font-weight:600;color:#6f6f7a;font-size:11px;letter-spacing:.04em}
        .mono{font-family:ui-monospace,"SF Mono",Menlo,monospace;font-size:11px}
        .num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
        .mark{width:18px;text-align:center;color:#b04a3c}
        .muted{color:#6f6f7a;font-size:12px}
        footer{margin-top:28px;color:#8a8a94;font-size:11px;line-height:1.6}
        </style></head><body><main>
        <h1>TouchFlow · 只读面板</h1>
        <p class="sub">\(escape(snapshot.device.name)) · 生成于 \(escape(generated))</p>
        <div class="card"><div class="kv">
        <div>设备 ID</div><div class="mono">\(escape(snapshot.device.deviceID))</div>
        <div>指纹</div><div class="mono">\(escape(snapshot.device.fingerprint))</div>
        <div>生效版本</div><div class="mono">\(escape(effective))</div>
        <div>本机已应用</div><div class="mono">\(escape(applied))</div>
        <div>版本 / 已配对</div><div>\(snapshot.versions.count) / \(snapshot.peers.count)</div>
        </div></div>
        <h2>版本历史</h2>
        \(snapshot.versions.isEmpty ? "<p class=\"muted\">还没有版本。</p>" : """
        <table><thead><tr><th></th><th>版本</th><th>名称</th><th class="num">规则</th><th>来源设备</th><th class="num">创建 (ms)</th><th></th></tr></thead>
        <tbody>\(rows)</tbody></table>
        """)
        <p class="muted">▶ = 生效版本　● = 该来源设备的当前指针</p>
        <h2>设备指针</h2>
        \(snapshot.pointers.isEmpty ? "<p class=\"muted\">没有指针。</p>" : """
        <table><thead><tr><th>设备</th><th>版本</th><th class="num">更新 (ms)</th></tr></thead><tbody>\(pointers)</tbody></table>
        """)
        <h2>已配对设备</h2>
        \(snapshot.peers.isEmpty ? "<p class=\"muted\">尚未配对其它设备。</p>" : """
        <table><thead><tr><th>设备</th><th>指纹</th><th class="num">最近可见 (ms)</th></tr></thead><tbody>\(peers)</tbody></table>
        """)
        <footer>\(escape(snapshot.notice))<br>此页面不包含任何写操作；令牌可随时在设备上轮换。</footer>
        </main></body></html>
        """
    }

    private static func short(_ id: String) -> String {
        id.count > 12 ? String(id.prefix(12)) + "…" : id
    }

    static func escape(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
