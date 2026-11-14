package app.leapin.mobile.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.leapin.mobile.ConsoleStore
import app.leapin.mobile.ControlConnection
import kotlinx.coroutines.CoroutineScope

@Composable
fun ConnectionsScreen(store: ConsoleStore, scope: CoroutineScope) {
    var query by remember { mutableStateOf("") }
    val filtered = remember(store.connections, query) {
        val needle = query.trim().lowercase()
        if (needle.isEmpty()) store.connections
        else store.connections.filter {
            it.host.lowercase().contains(needle) ||
                it.sourceApp.lowercase().contains(needle) ||
                it.policy.lowercase().contains(needle) ||
                it.outbound.lowercase().contains(needle)
        }
    }

    Column(Modifier.fillMaxSize()) {
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            placeholder = { Text("搜索域名、App 或策略", fontSize = 13.sp) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = LP.gutter, vertical = 8.dp),
        )

        if (store.connections.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("还没有连接记录", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = LP.text)
                    Text("在 Mac 上访问任意网站，这里会实时出现", fontSize = 12.sp, color = LP.textTertiary)
                }
            }
        } else {
            LazyColumn(
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    start = LP.gutter, end = LP.gutter, top = 4.dp, bottom = 16.dp
                ),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(filtered) { connection -> ConnectionCard(connection) }
                if (filtered.isEmpty()) {
                    item {
                        Text(
                            "没有匹配「$query」的连接",
                            fontSize = 12.sp,
                            color = LP.textTertiary,
                            modifier = Modifier.padding(top = 20.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ConnectionCard(connection: ControlConnection) {
    Panel {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                connection.host,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = LP.text,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            if (connection.port != 443) {
                Text(":${connection.port}", fontSize = 11.sp, color = LP.textTertiary, fontFamily = FontFamily.Monospace)
            }
            Pill(connection.policy, policyTint(connection.policy))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(
                connection.sourceApp.ifEmpty { "未知来源" },
                fontSize = 11.sp,
                color = LP.textSecondary,
                maxLines = 1,
            )
            Text(
                connection.outbound.ifEmpty { "—" },
                fontSize = 11.sp,
                color = LP.textTertiary,
                maxLines = 1,
            )
            Box(Modifier.weight(1f))
            Text(
                "${formatBytes(connection.bytesIn)} ↓ / ${formatBytes(connection.bytesOut)} ↑",
                fontSize = 10.sp,
                color = LP.textTertiary,
                fontFamily = FontFamily.Monospace,
            )
        }
        if (connection.matchedRule.isNotEmpty()) {
            Text(
                connection.matchedRule,
                fontSize = 10.sp,
                color = LP.textTertiary,
                fontFamily = FontFamily.Monospace,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun policyTint(policy: String): Color = when (policy.lowercase()) {
    "proxy", "global", "proxy-group" -> LP.accent
    "direct" -> LP.mint
    "reject", "block" -> LP.danger
    else -> LP.violet
}
