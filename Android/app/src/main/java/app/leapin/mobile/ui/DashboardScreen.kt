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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.leapin.mobile.ConsoleStore
import app.leapin.mobile.LocalProxy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

@Composable
fun DashboardScreen(store: ConsoleStore, scope: CoroutineScope) {
    val status = store.status
    var reloading by remember { mutableStateOf(false) }
    var reloadSummary by remember { mutableStateOf<String?>(null) }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = LP.gutter, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        PageHeader(
            "这台手机的网络",
            if (LocalProxy.isRunning) "引擎运行中 · 127.0.0.1:${LocalProxy.port}" else "本机引擎未启动",
        )

        FocusBand(eyebrow = "现在") {
            RouteLine(listOf("你", "本机引擎", "直连"), 1)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Fact("连接", "${status?.activeConnections ?: 0}", modifier = Modifier.weight(1f))
                Fact("规则", "${status?.ruleCount ?: 0}", modifier = Modifier.weight(1f))
                Fact("运行", formatDuration(status?.uptimeSeconds ?: 0.0), mono = false, modifier = Modifier.weight(1f))
                Fact("引擎", if (LocalProxy.isRunning) "运行中" else "已停止", mono = false, modifier = Modifier.weight(1f))
            }
            OnInkButton(
                text = if (LocalProxy.isRunning) "停止本机引擎" else "启动本机引擎",
                onClick = { if (LocalProxy.isRunning) LocalProxy.stop() else LocalProxy.start() },
            )
        }

        val state = status?.engineState ?: "unknown"
        Panel {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(
                    Modifier.size(44.dp).background(stateTint(state).copy(alpha = 0.14f), CircleShape),
                    contentAlignment = Alignment.Center,
                ) { Box(Modifier.size(9.dp).background(stateTint(state), CircleShape)) }
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(stateTitle(state), fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = LP.text)
                        Pill(state, stateTint(state))
                    }
                    Text(stateSubtitle(state), fontSize = 12.sp, color = LP.textTertiary)
                }
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.weight(1f)) {
                Panel {
                    Stat(
                        "活动连接",
                        "${status?.activeConnections ?: 0}",
                        tint = if ((status?.activeConnections ?: 0) == 0) LP.text else LP.accent,
                    )
                }
            }
            Box(Modifier.weight(1f)) {
                Panel { Stat("规则", "${status?.ruleCount ?: 0}") }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.weight(1f)) {
                Panel { Stat("已运行", formatDuration(status?.uptimeSeconds ?: 0.0)) }
            }
            Box(Modifier.weight(1f)) {
                Panel { Stat("去广告规则", "${status?.adblockRuleCount ?: 0}") }
            }
        }

        Panel(title = "监听端口", subtitle = "本机代理入口") {
            KeyValue("混合代理", "${status?.mixedPort ?: 0}", mono = true)
            KeyValue("HTTP", "${status?.httpPort ?: 0}", mono = true)
            KeyValue("SOCKS5", "${status?.socksPort ?: 0}", mono = true)
            KeyValue("控制面", "${status?.controlPort ?: 0}", mono = true)
            KeyValue("系统代理", if (status?.systemProxyActive == true) "已开启" else "未开启")
        }

        Panel(title = "操作") {
            Button(
                onClick = {
                    reloading = true
                    scope.launch {
                        val result = store.reload()
                        reloading = false
                        if (result != null) {
                            reloadSummary = "已重载 ${result.ruleCount} 条规则（${result.applied} 项生效，用时 ${formatMs(result.elapsedMs)}）"
                        }
                    }
                },
                enabled = !reloading,
                colors = ButtonDefaults.buttonColors(containerColor = LP.accentFill),
                modifier = Modifier.fillMaxWidth().height(46.dp),
            ) {
                if (reloading) {
                    CircularProgressIndicator(Modifier.size(15.dp), color = Color.White, strokeWidth = 2.dp)
                    Text("  正在重载…", fontWeight = FontWeight.SemiBold)
                } else {
                    Text("重载规则", fontWeight = FontWeight.SemiBold)
                }
            }
            reloadSummary?.let { Text(it, fontSize = 11.sp, color = LP.textTertiary) }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            if (store.isRefreshing) CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp, color = LP.textTertiary)
            Text("更新于 ${formatAgo(store.lastUpdated)}", fontSize = 11.sp, color = LP.textTertiary)
        }
        Box(Modifier.height(8.dp))
    }
}

private fun stateTitle(state: String) = when (state) {
    "running" -> "正在保护"
    "starting" -> "正在启动"
    "stopped" -> "已停止"
    "failed" -> "启动失败"
    else -> "未知状态"
}

private fun stateSubtitle(state: String) = when (state) {
    "running" -> "代理与规则引擎均已就绪"
    "starting" -> "内核正在初始化，稍候"
    "stopped" -> "在 Mac 上点「连接网络」即可开始"
    "failed" -> "请回到 Mac 查看错误详情"
    else -> "还没有收到状态"
}

@Composable
private fun stateTint(state: String): Color = when (state) {
    "running" -> LP.mint
    "starting" -> LP.amber
    "failed" -> LP.danger
    else -> LP.textTertiary
}
