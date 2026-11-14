package app.leapin.mobile.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import app.leapin.mobile.ControlPolicyGroup
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

@Composable
fun PoliciesScreen(store: ConsoleStore, scope: CoroutineScope) {
    var pending by remember { mutableStateOf<Pair<String, String>?>(null) }

    LaunchedEffect(store.endpoint) {
        if (store.policies.isEmpty()) store.loadPolicies()
    }

    if (store.policies.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("没有策略组", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = LP.text)
                Text("在 Mac 的配置里添加代理组后会自动出现", fontSize = 12.sp, color = LP.textTertiary)
            }
        }
        return
    }

    LazyColumn(
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            start = LP.gutter, end = LP.gutter, top = 10.dp, bottom = 16.dp
        ),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        items(store.policies, key = { it.name }) { group ->
            PolicyCard(group) { member -> pending = group.name to member }
        }
    }

    pending?.let { (groupName, outbound) ->
        AlertDialog(
            onDismissRequest = { pending = null },
            title = { Text("切换到 $outbound？") },
            text = { Text("$groupName 会立即改用该节点，影响所有走这条策略的连接。", fontSize = 13.sp) },
            confirmButton = {
                TextButton(onClick = {
                    pending = null
                    scope.launch { store.select(groupName, outbound) }
                }) { Text("切换", color = LP.accent) }
            },
            dismissButton = { TextButton(onClick = { pending = null }) { Text("取消") } },
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun PolicyCard(group: ControlPolicyGroup, onPick: (String) -> Unit) {
    Panel {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(group.name, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = LP.text)
                Text(typeLabel(group.type), fontSize = 11.sp, color = LP.textTertiary)
            }
            Pill(group.effective.ifEmpty { group.selected }, LP.accent, filled = true)
        }
        if (group.selected != group.effective && group.effective.isNotEmpty()) {
            Text("已选 ${group.selected}，实际走 ${group.effective}", fontSize = 11.sp, color = LP.amber)
        }
        if (group.members.isNotEmpty()) {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                group.members.forEach { member ->
                    MemberChip(member, selected = member == group.selected) { onPick(member) }
                }
            }
        }
    }
}

@Composable
private fun MemberChip(name: String, selected: Boolean, onClick: () -> Unit) {
    Surface(
        color = if (selected) LP.accentFill else LP.panel,
        shape = RoundedCornerShape(6.dp),
        border = if (selected) null
                 else androidx.compose.foundation.BorderStroke(1.dp, LP.stroke),
        onClick = onClick,
    ) {
        Text(
            name,
            fontSize = 11.sp,
            color = if (selected) Color.White else LP.textSecondary,
            modifier = Modifier.padding(horizontal = 9.dp, vertical = 6.dp),
        )
    }
}

private fun typeLabel(type: String): String = when (type.lowercase()) {
    "select" -> "手动选择"
    "urltest", "fallback" -> "自动测速"
    "loadbalance" -> "负载均衡"
    else -> type.ifEmpty { "代理组" }
}
