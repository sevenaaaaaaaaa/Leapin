package app.leapin.mobile

import org.json.JSONArray
import org.json.JSONObject

/**
 * Wire models for the desktop control plane (`/v1/...`).
 *
 * Field names mirror `Sources/LeapinControl/ControlContract.swift` exactly; the
 * desktop is the source of truth and this client never invents fields.
 */

data class ControlStatus(
    val engineState: String,
    val mixedPort: Int,
    val httpPort: Int,
    val socksPort: Int,
    val controlPort: Int,
    val ruleCount: Int,
    val adblockRuleCount: Int,
    val activeConnections: Int,
    val systemProxyActive: Boolean,
    val uptimeSeconds: Double,
    val version: String,
) {
    companion object {
        fun parse(o: JSONObject) = ControlStatus(
            engineState = o.optString("engineState", "unknown"),
            mixedPort = o.optInt("mixedPort"),
            httpPort = o.optInt("httpPort"),
            socksPort = o.optInt("socksPort"),
            controlPort = o.optInt("controlPort"),
            ruleCount = o.optInt("ruleCount"),
            adblockRuleCount = o.optInt("adblockRuleCount"),
            activeConnections = o.optInt("activeConnections"),
            systemProxyActive = o.optBoolean("systemProxyActive"),
            uptimeSeconds = o.optDouble("uptimeSeconds", 0.0),
            version = o.optString("version", ""),
        )
    }
}

data class ControlConnection(
    val id: String,
    val host: String,
    val port: Int,
    val policy: String,
    val matchedRule: String,
    val outbound: String,
    val sourceApp: String,
    val bytesIn: Long,
    val bytesOut: Long,
    val durationMs: Double,
) {
    companion object {
        fun parse(o: JSONObject) = ControlConnection(
            id = o.optString("id"),
            host = o.optString("host"),
            port = o.optInt("port"),
            policy = o.optString("policy"),
            matchedRule = o.optString("matchedRule"),
            outbound = o.optString("outbound"),
            sourceApp = o.optString("sourceApp"),
            bytesIn = o.optLong("bytesIn"),
            bytesOut = o.optLong("bytesOut"),
            durationMs = o.optDouble("durationMs", 0.0),
        )
    }
}

data class ControlPolicyGroup(
    val name: String,
    val type: String,
    val selected: String,
    val effective: String,
    val members: List<String>,
) {
    companion object {
        fun parse(o: JSONObject) = ControlPolicyGroup(
            name = o.optString("name"),
            type = o.optString("type"),
            selected = o.optString("selected"),
            effective = o.optString("effective"),
            members = o.optJSONArray("members").toStringList(),
        )
    }
}

data class RuleDiagnostic(val raw: String, val reason: String)

data class ExplainResult(
    val host: String,
    val port: Int,
    val policy: String,
    val matchedRule: String,
    val outbound: String,
    val chainSummary: String,
    val trace: List<String>,
    val isBlocked: Boolean,
    val diagnostics: List<RuleDiagnostic>,
) {
    companion object {
        fun parse(o: JSONObject): ExplainResult {
            val diag = mutableListOf<RuleDiagnostic>()
            o.optJSONArray("diagnostics")?.let { array ->
                for (i in 0 until array.length()) {
                    val item = array.optJSONObject(i) ?: continue
                    diag += RuleDiagnostic(item.optString("raw"), item.optString("reason"))
                }
            }
            return ExplainResult(
                host = o.optString("host"),
                port = o.optInt("port", 443),
                policy = o.optString("policy"),
                matchedRule = o.optString("matchedRule"),
                outbound = o.optString("outbound"),
                chainSummary = o.optString("chainSummary"),
                trace = o.optJSONArray("trace").toStringList(),
                isBlocked = o.optBoolean("isBlocked"),
                diagnostics = diag,
            )
        }
    }
}

data class DnsStep(val stage: String, val detail: String, val elapsedMs: Double)

data class DnsTrace(
    val host: String,
    val source: String,
    val resolved: List<String>,
    val upstream: String?,
    val elapsedMs: Double,
    val steps: List<DnsStep>,
    val error: String?,
) {
    companion object {
        fun parse(o: JSONObject): DnsTrace {
            val s = mutableListOf<DnsStep>()
            o.optJSONArray("steps")?.let { array ->
                for (i in 0 until array.length()) {
                    val item = array.optJSONObject(i) ?: continue
                    s += DnsStep(
                        item.optString("stage"),
                        item.optString("detail"),
                        item.optDouble("elapsedMs", 0.0),
                    )
                }
            }
            return DnsTrace(
                host = o.optString("host"),
                source = o.optString("source"),
                resolved = o.optJSONArray("resolved").toStringList(),
                upstream = o.optString("upstream").takeIf { it.isNotEmpty() },
                elapsedMs = o.optDouble("elapsedMs", 0.0),
                steps = s,
                error = o.optString("error").takeIf { it.isNotEmpty() },
            )
        }
    }
}

data class HttpProbe(
    val url: String,
    val statusCode: Int?,
    val elapsedMs: Double,
    val remoteAddress: String?,
    val tls: Boolean,
    val httpVersion: String?,
    val headerBytes: Int,
    val bodyBytes: Int,
    val redirects: Int,
    val error: String?,
) {
    companion object {
        fun parse(o: JSONObject) = HttpProbe(
            url = o.optString("url"),
            statusCode = if (o.has("statusCode") && !o.isNull("statusCode")) o.optInt("statusCode") else null,
            elapsedMs = o.optDouble("elapsedMs", 0.0),
            remoteAddress = o.optString("remoteAddress").takeIf { it.isNotEmpty() },
            tls = o.optBoolean("tls"),
            httpVersion = o.optString("httpVersion").takeIf { it.isNotEmpty() },
            headerBytes = o.optInt("headerBytes"),
            bodyBytes = o.optInt("bodyBytes"),
            redirects = o.optInt("redirects"),
            error = o.optString("error").takeIf { it.isNotEmpty() },
        )
    }
}

data class ReloadResult(val ruleCount: Int, val applied: Int, val elapsedMs: Double) {
    companion object {
        fun parse(o: JSONObject) = ReloadResult(
            ruleCount = o.optInt("ruleCount"),
            applied = o.optJSONArray("applied")?.length() ?: 0,
            elapsedMs = o.optDouble("elapsedMs", 0.0),
        )
    }
}

internal fun JSONArray?.toStringList(): List<String> {
    if (this == null) return emptyList()
    val out = ArrayList<String>(length())
    for (i in 0 until length()) out += optString(i)
    return out
}
