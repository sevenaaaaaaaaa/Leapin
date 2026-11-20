package app.leapin.mobile.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.leapin.mobile.ConsoleStore
import app.leapin.mobile.LocalProxy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.URL

/**
 * Things the phone can do on its own.
 *
 * The console tabs need a paired Mac; starting the app on a pairing screen made it
 * useless until the user walked back to the desktop for a token. This page is the
 * default tab and needs no pairing at all.
 */
@Composable
fun ToolsScreen(store: ConsoleStore, scope: CoroutineScope, onConnect: () -> Unit) {
    var localAddress by remember { mutableStateOf<String?>(null) }
    var publicAddress by remember { mutableStateOf<String?>(null) }
    var publicBusy by remember { mutableStateOf(false) }
    var publicError by remember { mutableStateOf<String?>(null) }

    var host by remember { mutableStateOf("") }
    var dnsResult by remember { mutableStateOf<List<String>>(emptyList()) }
    var dnsError by remember { mutableStateOf<String?>(null) }
    var dnsBusy by remember { mutableStateOf(false) }

    var url by remember { mutableStateOf("https://example.com") }
    var probeStatus by remember { mutableStateOf<Int?>(null) }
    var probeError by remember { mutableStateOf<String?>(null) }
    var probeBusy by remember { mutableStateOf(false) }

    androidx.compose.runtime.LaunchedEffect(Unit) {
        localAddress = withContext(Dispatchers.IO) { wifiAddress() }
    }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = LP.gutter, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Panel {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(
                        if (store.endpoint == null) "未连接 Mac" else "已连接 ${store.endpoint?.display}",
                        fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = LP.text,
                    )
                    Text(
                        if (store.endpoint == null)
                            "连接后可查看 Mac 的分流、连接与抓包；下面这些工具不需要连接。"
                        else "状态、连接、策略、诊断四个页面可用。",
                        fontSize = 11.sp, color = LP.textTertiary,
                    )
                }
                if (store.endpoint == null) {
                    TextButton(onClick = onConnect) { Text("连接", color = LP.accent) }
                }
            }
        }


        Panel(title = "本机代理引擎", subtitle = "在手机上直接跑代理，不经过 Mac") {
            KeyValue("状态", if (LocalProxy.isRunning) "运行中 · 127.0.0.1:" + LocalProxy.port else "未启动", mono = LocalProxy.isRunning)
            LocalProxy.lastError?.let { Text(it, fontSize = 11.sp, color = LP.danger) }
            LocalProxy.lastCheck?.let {
                Text(it, fontSize = 11.sp, color = if (it.contains("失败")) LP.danger else LP.textTertiary)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = { if (LocalProxy.isRunning) LocalProxy.stop() else LocalProxy.start() },
                    colors = ButtonDefaults.buttonColors(containerColor = LP.accent),
                ) { Text(if (LocalProxy.isRunning) "停止" else "启动", color = Color.White, fontSize = 13.sp) }
                if (LocalProxy.isRunning) {
                    TextButton(
                        onClick = { scope.launch { LocalProxy.selfCheck() } },
                        enabled = !LocalProxy.isChecking,
                    ) { Text(if (LocalProxy.isChecking) "测试中…" else "经代理访问 example.com", color = LP.accent, fontSize = 12.sp) }
                }
            }
            Text(
                "这一层就是 VpnService 之后要接进来的同一个引擎：现在是手机自己监听 127.0.0.1，下一步由系统把流量导进来。",
                fontSize = 10.sp, color = LP.textTertiary,
            )
        }

        Panel(title = "本机网络", subtitle = "不需要连接 Mac") {
            KeyValue("局域网地址", localAddress ?: "读取中…", mono = true)
            KeyValue("公网出口", publicAddress ?: if (publicBusy) "查询中…" else "未获取", mono = true)
            publicError?.let { Text(it, fontSize = 11.sp, color = LP.danger) }
            TextButton(
                onClick = {
                    publicBusy = true
                    publicError = null
                    scope.launch {
                        try {
                            publicAddress = withContext(Dispatchers.IO) { fetchPublicAddress() }
                        } catch (e: Exception) {
                            publicError = "公网地址查询失败：${e.message ?: "网络错误"}"
                        }
                        publicBusy = false
                    }
                },
                enabled = !publicBusy,
            ) { Text(if (publicBusy) "查询中…" else "查询公网地址", color = LP.accent, fontSize = 12.sp) }
        }

        Panel(title = "DNS 解析", subtitle = "直接在本机解析，不经 Mac") {
            OutlinedTextField(
                value = host, onValueChange = { host = it },
                label = { Text("域名") },
                singleLine = true,
                textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )
            Button(
                onClick = {
                    val name = host.trim()
                    if (name.isEmpty()) { dnsError = "请输入域名"; return@Button }
                    dnsBusy = true; dnsError = null; dnsResult = emptyList()
                    scope.launch {
                        try {
                            dnsResult = withContext(Dispatchers.IO) {
                                InetAddress.getAllByName(name).map { it.hostAddress ?: it.toString() }.distinct()
                            }
                            if (dnsResult.isEmpty()) dnsError = "没有解析结果"
                        } catch (e: Exception) {
                            dnsError = "解析失败，检查域名或网络"
                        }
                        dnsBusy = false
                    }
                },
                enabled = !dnsBusy,
                colors = ButtonDefaults.buttonColors(containerColor = LP.accentFill),
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (dnsBusy) {
                    CircularProgressIndicator(Modifier.size(14.dp), color = Color.White, strokeWidth = 2.dp)
                    Text("  处理中…", fontSize = 13.sp)
                } else Text("解析", fontSize = 13.sp)
            }
            dnsError?.let { Text(it, fontSize = 11.sp, color = LP.danger) }
            dnsResult.forEach { MonoText(it, size = 11, color = LP.textSecondary) }
        }

        Panel(title = "HTTP 探测", subtitle = "从手机直接发请求") {
            OutlinedTextField(
                value = url, onValueChange = { url = it },
                label = { Text("URL") },
                singleLine = true,
                textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )
            Button(
                onClick = {
                    val target = url.trim()
                    if (!target.startsWith("http")) { probeError = "请输入完整 URL"; return@Button }
                    probeBusy = true; probeError = null; probeStatus = null
                    scope.launch {
                        try {
                            probeStatus = withContext(Dispatchers.IO) { probe(target) }
                        } catch (e: Exception) {
                            probeError = "请求失败：${e.message ?: "网络错误"}"
                        }
                        probeBusy = false
                    }
                },
                enabled = !probeBusy,
                colors = ButtonDefaults.buttonColors(containerColor = LP.accentFill),
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (probeBusy) {
                    CircularProgressIndicator(Modifier.size(14.dp), color = Color.White, strokeWidth = 2.dp)
                    Text("  探测中…", fontSize = 13.sp)
                } else Text("探测", fontSize = 13.sp)
            }
            probeError?.let { Text(it, fontSize = 11.sp, color = LP.danger) }
            probeStatus?.let { code ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Pill("$code", if (code in 200..399) LP.mint else LP.amber, filled = true)
                }
            }
        }

        Text(
            "需要查看 Mac 的分流、连接与抓包时，再连接一次即可。工具页始终可用。",
            fontSize = 11.sp, color = LP.textTertiary,
        )
        Box(Modifier.padding(bottom = 8.dp))
    }
}

private fun wifiAddress(): String? {
    return try {
        val interfaces = NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
        for (nif in interfaces) {
            if (!nif.isUp || nif.isLoopback) continue
            for (address in nif.inetAddresses.toList()) {
                if (address is Inet4Address && !address.isLoopbackAddress) {
                    return address.hostAddress
                }
            }
        }
        null
    } catch (e: Exception) {
        null
    }
}

/**
 * The tools page is the one page that works with no Mac, so a single unreachable host
 * must not turn it into an error — that is exactly what happened with api.ipify.org on
 * networks that block it. Endpoints are tried in order and the first body holding an
 * address wins.
 */
private val publicAddressEndpoints = listOf(
    "https://myip.ipip.net",   // answers 当前 IP：1.2.3.4 来自于：…
    "https://api.ip.sb/ip",
    "https://ifconfig.me/ip",
    "https://api.ipify.org",
)

private val publicAddressPattern = Regex("""(?:\d{1,3}\.){3}\d{1,3}""")

private fun parsePublicAddress(body: String): String? =
    publicAddressPattern.find(body)?.value?.takeIf { candidate ->
        val parts = candidate.split('.')
        parts.size == 4 && parts.all { part -> part.toIntOrNull()?.let { it in 0..255 } == true }
    }

private fun fetchPublicAddress(): String {
    var last: Exception? = null
    for (endpoint in publicAddressEndpoints) {
        try {
            val connection = (URL(endpoint).openConnection() as HttpURLConnection).apply {
                connectTimeout = 6000
                readTimeout = 6000
            }
            try {
                val body = connection.inputStream.bufferedReader().use { it.readText() }
                parsePublicAddress(body)?.let { return it }
            } finally {
                connection.disconnect()
            }
        } catch (e: Exception) {
            last = e
        }
    }
    throw last ?: Exception("网络错误")
}

private fun probe(target: String): Int {
    val connection = (URL(target).openConnection() as HttpURLConnection).apply {
        requestMethod = "HEAD"
        instanceFollowRedirects = true
        connectTimeout = 8000
        readTimeout = 8000
    }
    try {
        return connection.responseCode
    } finally {
        connection.disconnect()
    }
}