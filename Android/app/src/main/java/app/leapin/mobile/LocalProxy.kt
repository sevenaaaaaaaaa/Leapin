package app.leapin.mobile

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.leapin.mobile.proxy.ProxyEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL

/**
 * The phone's own proxy, not the Mac's.
 *
 * This is the engine a VpnService will hand traffic to: it listens on loopback and
 * speaks SOCKS5 and HTTP (CONNECT and absolute-form). Kept as a small state holder
 * so the tools page can start it, stop it and prove it moves bytes.
 */
object LocalProxy {
    private var engine: ProxyEngine? = null

    var isRunning by mutableStateOf(false)
        private set
    var port by mutableStateOf(0)
        private set
    var lastError by mutableStateOf<String?>(null)
        private set
    var lastCheck by mutableStateOf<String?>(null)
        private set
    var isChecking by mutableStateOf(false)
        private set

    fun start() {
        if (isRunning) return
        try {
            val fresh = ProxyEngine(0)
            fresh.start()
            engine = fresh
            port = fresh.port
            isRunning = true
            lastError = null
        } catch (error: Throwable) {
            lastError = error.message ?: "无法启动本机代理"
        }
    }

    fun stop() {
        engine?.stop()
        engine = null
        isRunning = false
        port = 0
    }

    /** Fetches a URL through the local proxy: success means bytes really moved. */
    suspend fun selfCheck(url: String = "https://example.com") {
        if (!isRunning) return
        isChecking = true
        try {
            val text = withContext(Dispatchers.IO) {
                val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", port))
                val connection = URL(url).openConnection(proxy) as HttpURLConnection
                connection.connectTimeout = 10_000
                connection.readTimeout = 10_000
                connection.requestMethod = "GET"
                try {
                    val code = connection.responseCode
                    val stream = if (code in 200..299) connection.inputStream else connection.errorStream
                    val bytes = stream?.readBytes()?.size ?: 0
                    "经本机代理 http://127.0.0.1:" + port + " 收到 HTTP " + code + "，" + bytes + " 字节"
                } finally {
                    connection.disconnect()
                }
            }
            lastCheck = text
        } catch (error: Throwable) {
            lastCheck = "经本机代理失败：" + (error.message ?: "网络错误")
        } finally {
            isChecking = false
        }
    }
}
