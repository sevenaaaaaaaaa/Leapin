package app.leapin.mobile

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.BufferedReader
import java.net.HttpURLConnection
import java.net.URL

/** Where the Mac control plane lives, plus the bearer token that unlocks it. */
data class Endpoint(val host: String, val port: Int, val token: String) {
    val display: String get() = "$host:$port"

    companion object {
        /** Trims input, drops a pasted scheme or trailing slash, splits host:port. */
        fun parse(hostRaw: String, portRaw: String, tokenRaw: String): Endpoint? {
            var host = hostRaw.trim()
            val token = tokenRaw.trim()
            if (host.isEmpty() || token.isEmpty()) return null
            for (prefix in listOf("http://", "https://")) {
                if (host.startsWith(prefix, ignoreCase = true)) host = host.substring(prefix.length)
            }
            host = host.trimEnd('/')
            var port = portRaw.trim().toIntOrNull() ?: 7900
            val colon = host.lastIndexOf(':')
            if (colon > 0) {
                val tail = host.substring(colon + 1)
                if (tail.isNotEmpty() && tail.all { it.isDigit() }) {
                    port = tail.toIntOrNull() ?: port
                    host = host.substring(0, colon)
                }
            }
            if (host.isEmpty() || port !in 1..65535) return null
            return Endpoint(host, port, token)
        }
    }
}

class ControlException(message: String) : Exception(message)

/**
 * Thin client for the desktop action API. Uses HttpURLConnection on purpose:
 * the payloads are small and this keeps the APK free of a network dependency.
 */
class ControlClient(private val endpoint: Endpoint) {

    suspend fun status(): ControlStatus = withContext(Dispatchers.IO) {
        ControlStatus.parse(request("/v1/status"))
    }

    suspend fun connections(limit: Int = 60): List<ControlConnection> = withContext(Dispatchers.IO) {
        val body = request("/v1/connections?limit=$limit")
        val array = body.optJSONArray("connections") ?: return@withContext emptyList()
        (0 until array.length()).mapNotNull { i ->
            array.optJSONObject(i)?.let { ControlConnection.parse(it) }
        }
    }

    suspend fun policies(): List<ControlPolicyGroup> = withContext(Dispatchers.IO) {
        val body = request("/v1/policies")
        val array = body.optJSONArray("policies") ?: return@withContext emptyList()
        (0 until array.length()).mapNotNull { i ->
            array.optJSONObject(i)?.let { ControlPolicyGroup.parse(it) }
        }
    }

    suspend fun select(group: String, outbound: String): Unit = withContext(Dispatchers.IO) {
        request("/v1/policies/select", "POST", JSONObject()
            .put("group", group)
            .put("outbound", outbound))
        Unit
    }

    suspend fun reload(): ReloadResult = withContext(Dispatchers.IO) {
        ReloadResult.parse(request("/v1/reload", "POST", JSONObject()))
    }

    suspend fun explain(host: String, port: Int): ExplainResult = withContext(Dispatchers.IO) {
        ExplainResult.parse(request("/v1/explain", "POST", JSONObject()
            .put("host", host)
            .put("port", port)))
    }

    suspend fun dnsTrace(host: String): DnsTrace = withContext(Dispatchers.IO) {
        val body = request("/v1/dns/trace", "POST", JSONObject().put("host", host))
        val trace = body.optJSONObject("trace") ?: throw ControlException("响应缺少 trace 字段")
        DnsTrace.parse(trace)
    }

    suspend fun httpProbe(url: String, timeoutMs: Int = 10_000): HttpProbe = withContext(Dispatchers.IO) {
        val body = request("/v1/http/probe", "POST", JSONObject()
            .put("url", url)
            .put("timeoutMs", timeoutMs))
        val probe = body.optJSONObject("probe") ?: throw ControlException("响应缺少 probe 字段")
        HttpProbe.parse(probe)
    }

    private fun request(path: String, method: String = "GET", payload: JSONObject? = null): JSONObject {
        val url = URL("http://${endpoint.host}:${endpoint.port}$path")
        val connection = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 6_000
            readTimeout = 15_000
            setRequestProperty("Authorization", "Bearer ${endpoint.token}")
            setRequestProperty("Accept", "application/json")
            if (payload != null) {
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
        }
        try {
            if (payload != null) {
                connection.outputStream.use { it.write(payload.toString().toByteArray()) }
            }
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader()?.use(BufferedReader::readText).orEmpty()

            if (code == 401) throw ControlException("令牌无效或已轮换，请在 Mac 上重新读取 control-token")
            if (code !in 200..299) {
                val message = runCatching { JSONObject(text).optString("message") }.getOrNull()
                    ?.takeIf { it.isNotEmpty() } ?: "HTTP $code"
                throw ControlException("Mac 返回错误 $code：$message")
            }
            return runCatching { JSONObject(text) }
                .getOrElse { throw ControlException("响应格式无法解析，版本可能不匹配") }
        } catch (e: ControlException) {
            throw e
        } catch (e: Exception) {
            throw ControlException("无法连接到 Mac：${e.message ?: e::class.java.simpleName}")
        } finally {
            connection.disconnect()
        }
    }
}

/**
 * Stores the endpoint across launches. The token is encrypted with an AES key
 * held by the Android Keystore, so the plain value never lands in prefs.
 */
object EndpointStore {
    private const val PREFS = "leapin.endpoint"
    private const val KEY_HOST = "host"
    private const val KEY_PORT = "port"
    private const val KEY_TOKEN = "token"

    fun load(context: Context): Endpoint? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val host = prefs.getString(KEY_HOST, null)?.takeIf { it.isNotEmpty() } ?: return null
        val port = prefs.getInt(KEY_PORT, 7900)
        val sealed = prefs.getString(KEY_TOKEN, null)?.takeIf { it.isNotEmpty() } ?: return null
        val token = TokenVault.decrypt(sealed) ?: return null
        if (token.isEmpty()) return null
        return Endpoint(host, port, token)
    }

    fun save(context: Context, endpoint: Endpoint) {
        val sealed = TokenVault.encrypt(endpoint.token) ?: return
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_HOST, endpoint.host)
            .putInt(KEY_PORT, endpoint.port)
            .putString(KEY_TOKEN, sealed)
            .apply()
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
    }
}
