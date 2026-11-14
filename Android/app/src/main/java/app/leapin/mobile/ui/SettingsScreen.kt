package app.leapin.mobile.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.leapin.mobile.ConsoleStore
import kotlinx.coroutines.CoroutineScope

@Composable
fun SettingsScreen(store: ConsoleStore, scope: CoroutineScope, onBack: () -> Unit) {
    var confirm by remember { mutableStateOf(false) }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = LP.gutter, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Panel(title = "连接") {
            KeyValue("Mac 地址", store.endpoint?.display ?: "未连接", mono = true)
            KeyValue("版本", store.status?.version ?: "—")
            KeyValue("最近更新", formatAgo(store.lastUpdated))
        }

        Panel(title = "刷新") {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("自动刷新", fontSize = 14.sp, color = LP.text)
                    Text("每 5 秒从 Mac 拉取状态", fontSize = 11.sp, color = LP.textTertiary)
                }
                Switch(
                    checked = store.autoRefresh,
                    onCheckedChange = { store.updateAutoRefresh(it) },
                )
            }
        }

        OutlinedButton(onClick = { confirm = true }, modifier = Modifier.fillMaxWidth()) {
            Text("断开并清除令牌")
        }

        TextButton(onClick = onBack) { Text("返回") }

        Text(
            "Leapin Mobile 只读取你自己 Mac 的控制面，不代理手机流量。手机上的系统级 VPN 需要 VpnService 权限与用户手动授权，这一版没有包含。",
            fontSize = 11.sp,
            color = LP.textTertiary,
        )
    }

    if (confirm) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text("断开后需要重新输入令牌") },
            confirmButton = {
                TextButton(onClick = {
                    confirm = false
                    store.disconnect()
                }) { Text("断开", color = LP.danger) }
            },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text("取消") } },
        )
    }
}
