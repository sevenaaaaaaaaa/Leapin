package app.leapin.mobile.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.leapin.mobile.ConsoleStore
import kotlinx.coroutines.launch

/** First-run pairing: the phone needs the Mac's address and control token. */
@Composable
fun SetupScreen(store: ConsoleStore) {
    var host by remember { mutableStateOf("") }
    var port by remember { mutableStateOf("7900") }
    var token by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var validation by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    Column(
        Modifier
            .fillMaxSize()
            .background(LP.canvas)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = LP.gutter, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(
                Modifier
                    .size(28.dp)
                    .background(LP.accent, RoundedCornerShape(7.dp)),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.Bolt, contentDescription = null, tint = Color.White, modifier = Modifier.size(15.dp)) }
            Column {
                Text("Leapin", fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = LP.text)
                Text("手机端控制台", fontSize = 12.sp, color = LP.textTertiary)
            }
        }

        Panel(title = "连接 Mac", subtitle = "在同一个 Wi-Fi 下，控制本机的 Leapin") {
            OutlinedTextField(
                value = host, onValueChange = { host = it },
                label = { Text("IP 地址") },
                placeholder = { Text("192.168.1.10") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = port, onValueChange = { port = it },
                label = { Text("端口") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Next),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = token, onValueChange = { token = it },
                label = { Text("令牌 (control-token)") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                modifier = Modifier.fillMaxWidth(),
            )
        }

        Panel(title = "怎么拿到这些信息", subtitle = "在 Mac 上执行一次") {
            Step(1, "让控制面监听局域网", "leapin run（或桌面 App 点「连接网络」）")
            Step(2, "读取令牌", "cat ~/Library/Application\\ Support/Leapin/control-token")
            Step(3, "把 IP 和令牌填到这里", "IP 就是 Mac 在 Wi-Fi 里的地址")
        }

        validation?.let { Text(it, fontSize = 12.sp, color = LP.danger) }

        Button(
            onClick = {
                validation = null
                busy = true
                scope.launch {
                    val ok = store.connect(host, port, token)
                    busy = false
                    if (!ok) validation = store.lastError
                }
            },
            enabled = !busy,
            colors = ButtonDefaults.buttonColors(containerColor = LP.accentFill),
            modifier = Modifier.fillMaxWidth().height(48.dp),
        ) {
            if (busy) {
                CircularProgressIndicator(Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp)
                Spacer(Modifier.size(8.dp))
            }
            Text(if (busy) "正在连接…" else "连接", fontWeight = FontWeight.SemiBold)
        }

        Text("令牌用 Android Keystore 加密后保存在本机。", fontSize = 11.sp, color = LP.textTertiary)
    }
}

@Composable
private fun Step(index: Int, title: String, command: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(9.dp)) {
        Box(
            Modifier.size(18.dp).background(LP.accent.copy(alpha = 0.14f), RoundedCornerShape(9.dp)),
            contentAlignment = Alignment.Center,
        ) { Text("$index", fontSize = 10.sp, color = LP.accent) }
        Column {
            Text(title, fontSize = 12.sp, color = LP.text)
            Text(command, fontSize = 11.sp, color = LP.textTertiary, fontFamily = FontFamily.Monospace)
        }
    }
}
