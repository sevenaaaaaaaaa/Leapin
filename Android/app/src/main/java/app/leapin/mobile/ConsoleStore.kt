package app.leapin.mobile

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel

/**
 * Single source of truth for the console: one endpoint, one snapshot of the Mac
 * agent, and the actions the screens can trigger.
 */
class ConsoleStore(application: Application) : AndroidViewModel(application) {

    var endpoint by mutableStateOf(EndpointStore.load(application))
        private set
    var status by mutableStateOf<ControlStatus?>(null)
        private set
    var connections by mutableStateOf<List<ControlConnection>>(emptyList())
        private set
    var policies by mutableStateOf<List<ControlPolicyGroup>>(emptyList())
        private set
    var lastError by mutableStateOf<String?>(null)
        private set
    var isRefreshing by mutableStateOf(false)
        private set
    var lastUpdated by mutableStateOf<Long?>(null)
        private set
    var autoRefresh by mutableStateOf(true)
        private set

    val isConnected: Boolean get() = endpoint != null && status != null

    private fun client(): ControlClient? = endpoint?.let { ControlClient(it) }

    suspend fun connect(host: String, port: String, token: String): Boolean {
        val candidate = Endpoint.parse(host, port, token)
        if (candidate == null) {
            lastError = "请填写 Mac 的 IP、端口和令牌"
            return false
        }
        return try {
            val loaded = ControlClient(candidate).status()
            endpoint = candidate
            status = loaded
            EndpointStore.save(getApplication(), candidate)
            lastUpdated = System.currentTimeMillis()
            lastError = null
            refresh()
            true
        } catch (e: ControlException) {
            lastError = e.message
            false
        }
    }

    suspend fun refresh() {
        val client = client() ?: return
        if (isRefreshing) return
        isRefreshing = true
        try {
            val freshStatus = client.status()
            val freshConnections = client.connections()
            status = freshStatus
            connections = freshConnections
            lastUpdated = System.currentTimeMillis()
            lastError = null
        } catch (e: ControlException) {
            lastError = e.message
        } finally {
            isRefreshing = false
        }
        if (policies.isEmpty()) runCatching { policies = client.policies() }
    }

    suspend fun loadPolicies() {
        val client = client() ?: return
        try {
            policies = client.policies()
            lastError = null
        } catch (e: ControlException) {
            lastError = e.message
        }
    }

    suspend fun select(group: String, outbound: String): Boolean {
        val client = client() ?: return false
        return try {
            client.select(group, outbound)
            loadPolicies()
            true
        } catch (e: ControlException) {
            lastError = e.message
            false
        }
    }

    suspend fun reload(): ReloadResult? {
        val client = client() ?: return null
        return try {
            val result = client.reload()
            refresh()
            result
        } catch (e: ControlException) {
            lastError = e.message
            null
        }
    }

    suspend fun explain(host: String, port: Int): ExplainResult? {
        val client = client() ?: return null
        return try {
            client.explain(host, port)
        } catch (e: ControlException) {
            lastError = e.message
            null
        }
    }

    suspend fun dnsTrace(host: String): DnsTrace? {
        val client = client() ?: return null
        return try {
            client.dnsTrace(host)
        } catch (e: ControlException) {
            lastError = e.message
            null
        }
    }

    suspend fun probe(url: String): HttpProbe? {
        val client = client() ?: return null
        return try {
            client.httpProbe(url)
        } catch (e: ControlException) {
            lastError = e.message
            null
        }
    }

    fun updateAutoRefresh(enabled: Boolean) {
        autoRefresh = enabled
    }

    fun disconnect() {
        EndpointStore.clear(getApplication())
        endpoint = null
        status = null
        connections = emptyList()
        policies = emptyList()
        lastUpdated = null
        lastError = null
    }

    fun clearError() {
        lastError = null
    }
}
