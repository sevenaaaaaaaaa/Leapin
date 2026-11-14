package app.leapin.mobile.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
import app.leapin.mobile.DnsTrace
import app.leapin.mobile.ExplainResult
import app.leapin.mobile.HttpProbe
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

private val TOOLS = listOf("分流判定", "DNS 追踪", "HTTP 探测")

@Composable
fun DiagnosticsScreen(store: ConsoleStore, scope: CoroutineScope) {
    var tool by remember { mutableIntStateOf(0) }
    var host by remember { mutableStateOf("") }
    var port by remember { mutableStateOf("443") }
    var url by remember { mutableStateOf("https://example.com") }
    var busy by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }

    var explain by remember { mutableStateOf<ExplainResult?>(null) }
    var trace by remember { mutableStateOf<DnsTrace?>(null) }
    var probe by remember { mutableStateOf<HttpProbe?>(null) }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = LP.gutter, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        TabRow(selectedTabIndex = tool, containerColor = LP.panel) {
            TOOLS.forEachIndexed { index, title ->
                Tab(selected = tool == index, onClick = {
                    tool = index
                    failure = null; explain = null; trace = null; probe = null
                }, text = { Text(title, fontSize = 12.sp) })
            }
        }

        Panel(title = TOOLS[tool], subtitle = subtitleFor(tool)) {
            if (tool == 2) {
                OutlinedTextField(
                    value = url, onValueChange = { url = it },
                    label = { Text("URL") },
                    singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    modifier = Modifier.fillMaxWidth(),
                )
            } else {
                OutlinedTextField(
                    value = host, onValueChange = { host = it },
                    label = { Text("域名") },
                    placeholder = { Text("www.example.com") },
                    singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    modifier = Modifier.fillMaxWidth(),
                )
                if (tool == 0) {
                    OutlinedTextField(
                        value = port, onValueChange = { port = it },
                        label = { Text("端口") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }

        Button(
            onClick = {
                failure = null
                busy = true
                scope.launch {
                    when (tool) {
                        0 -> {
                            val target = host.trim()
                            if (target.isEmpty()) failure = "请填写域名"
                            else {
                                explain = store.explain(target, port.trim().toIntOrNull() ?: 443)
                                if (explain == null) failure = store.lastError
                            }
                        }
                        1 -> {
                            val target = host.trim()
                            if (target.isEmpty()) failure = "请填写域名"
                            else {
                                trace = store.dnsTrace(target)
                                if (trace == null) failure = store.lastError
                            }
                        }
                        else -> {
                            val target = url.trim()
                            if (target.isEmpty()) failure = "请填写 URL"
                            else {
                                probe = store.probe(target)
                                if (probe == null) failure = store.lastError
                            }
                        }
                    }
                    busy = false
                }
            },
            enabled = !busy,
            colors = ButtonDefaults.buttonColors(containerColor = LP.accentFill),
            modifier = Modifier.fillMaxWidth().height(46.dp),
        ) {
            if (busy) {
                CircularProgressIndicator(Modifier.size(15.dp), color = Color.White, strokeWidth = 2.dp)
                Text("  正在执行…", fontWeight = FontWeight.SemiBold)
            } else {
                Text("执行", fontWeight = FontWeight.SemiBold)
            }
        }

        failure?.let { Panel { Text(it, fontSize = 12.sp, color = LP.danger) } }

        explain?.let { ExplainCard(it) }
        trace?.let { TraceCard(it) }
        probe?.let { ProbeCard(it) }
        Box(Modifier.height(8.dp))
    }
}

@Composable
private fun ExplainCard(result: ExplainResult) {
    Panel(title = "判定结果", subtitle = "${result.host}:${result.port}") {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Pill(result.policy.ifEmpty { "未知" }, if (result.isBlocked) LP.danger else LP.accent, filled = true)
            if (result.outbound.isNotEmpty()) {
                Text("→ ${result.outbound}", fontSize = 11.sp, color = LP.textSecondary, fontFamily = FontFamily.Monospace)
            }
        }
        if (result.matchedRule.isNotEmpty()) KeyValue("命中规则", result.matchedRule, mono = true)
        if (result.chainSummary.isNotEmpty()) KeyValue("链路", result.chainSummary, mono = true)
        result.trace.forEach { MonoText(it, size = 10) }
        if (result.diagnostics.isNotEmpty()) {
            Text("规则诊断", fontSize = 11.sp, color = LP.textTertiary)
            result.diagnostics.forEach { item ->
                Column {
                    MonoText(item.raw, size = 10, color = LP.textSecondary)
                    Text(item.reason, fontSize = 11.sp, color = LP.amber)
                }
            }
        }
    }
}

@Composable
private fun TraceCard(result: DnsTrace) {
    Panel(title = "DNS 解析", subtitle = result.host) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Pill(sourceLabel(result.source), LP.violet)
            Text(formatMs(result.elapsedMs), fontSize = 11.sp, color = LP.textTertiary, fontFamily = FontFamily.Monospace)
        }
        result.upstream?.let { KeyValue("上游", it, mono = true) }
        if (result.resolved.isNotEmpty()) KeyValue("结果", result.resolved.joinToString("\n"), mono = true)
        result.error?.let { Text(it, fontSize = 12.sp, color = LP.danger) }
        result.steps.forEach { step ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
                Text(step.stage, fontSize = 10.sp, color = LP.accent, modifier = Modifier.weight(0.25f))
                Text(
                    step.detail, fontSize = 10.sp, color = LP.textTertiary,
                    fontFamily = FontFamily.Monospace, modifier = Modifier.weight(0.6f),
                )
                Text(formatMs(step.elapsedMs), fontSize = 9.sp, color = LP.textTertiary)
            }
        }
    }
}

@Composable
private fun ProbeCard(result: HttpProbe) {
    Panel(title = "HTTP 探测", subtitle = result.url) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            result.statusCode?.let { code ->
                Pill("$code", if (code in 200..399) LP.mint else LP.amber, filled = true)
            }
            if (result.tls) Pill("TLS", LP.mint)
            result.httpVersion?.let { Pill(it, LP.violet) }
            Box(Modifier.weight(1f))
            Text(formatMs(result.elapsedMs), fontSize = 11.sp, color = LP.textTertiary, fontFamily = FontFamily.Monospace)
        }
        result.remoteAddress?.let { KeyValue("远端", it, mono = true) }
        KeyValue("头/体", "${formatBytes(result.headerBytes.toLong())} / ${formatBytes(result.bodyBytes.toLong())}", mono = true)
        if (result.redirects > 0) KeyValue("跳转", "${result.redirects} 次")
        result.error?.let { Text(it, fontSize = 12.sp, color = LP.danger) }
    }
}

private fun subtitleFor(tool: Int) = when (tool) {
    0 -> "这个域名会走哪条策略"
    1 -> "解析过程与上游"
    else -> "从 Mac 发起请求，看真实结果"
}

private fun sourceLabel(raw: String) = when (raw) {
    "cache" -> "缓存"
    "fakeip" -> "FakeIP"
    "upstream" -> "上游"
    "system" -> "系统"
    else -> raw
}
