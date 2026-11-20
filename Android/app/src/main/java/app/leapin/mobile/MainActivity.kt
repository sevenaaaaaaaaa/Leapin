package app.leapin.mobile

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import app.leapin.mobile.ui.ConnectionsScreen
import app.leapin.mobile.ui.DashboardScreen
import app.leapin.mobile.ui.DiagnosticsScreen
import app.leapin.mobile.ui.ErrorBanner
import app.leapin.mobile.ui.LP
import app.leapin.mobile.ui.LeapinTheme
import app.leapin.mobile.ui.PoliciesScreen
import app.leapin.mobile.ui.SetupScreen
import app.leapin.mobile.ui.SettingsScreen
import app.leapin.mobile.ui.ToolsScreen
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            LeapinTheme {
                val store: ConsoleStore = viewModel()
                // The tools page needs no Mac, so the app never dead-ends on pairing.
                ConsoleScaffold(store)
            }
        }
    }
}

private data class Tab(val title: String, val icon: ImageVector)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConsoleScaffold(store: ConsoleStore) {
    val tabs = listOf(
        Tab("工具", Icons.Filled.Build),
        Tab("状态", Icons.Filled.Speed),
        Tab("连接", Icons.Filled.SwapHoriz),
        Tab("策略", Icons.Filled.Layers),
        Tab("诊断", Icons.Filled.MonitorHeart),
    )
    // Never open on pairing: the tabs are readable without a Mac, and the tools
    // page carries the "connect" entry. Starting on the setup screen is what made
    // the app feel like a dead end on first launch.
    var showSetup by remember { mutableStateOf(false) }
    var selected by remember { mutableIntStateOf(0) }
    var showSettings by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    // Live polling keeps the dashboard honest without a manual pull.
    LaunchedEffect(store.endpoint, store.autoRefresh) {
        if (store.autoRefresh) {
            while (true) {
                delay(5_000)
                store.refresh()
            }
        }
    }

    Scaffold(
        containerColor = LP.canvas,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            if (showSettings) "设置" else tabs[selected].title,
                            fontSize = 17.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        store.endpoint?.let {
                            Text(it.display, fontSize = 11.sp, color = LP.textTertiary)
                        }
                    }
                },
                actions = {
                    if (!showSettings) {
                        IconButton(onClick = { showSettings = true }) {
                            Icon(Icons.Filled.Settings, contentDescription = "设置", tint = LP.accent)
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = LP.canvas,
                    titleContentColor = LP.text,
                ),
            )
        },
        bottomBar = {
            if (!showSettings) {
                NavigationBar(containerColor = LP.panel) {
                    tabs.forEachIndexed { index, tab ->
                        NavigationBarItem(
                            selected = selected == index,
                            onClick = { selected = index },
                            icon = { Icon(tab.icon, contentDescription = tab.title) },
                            label = { Text(tab.title, fontSize = 11.sp) },
                        )
                    }
                }
            }
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            store.lastError?.let { message ->
                Box(Modifier.padding(horizontal = LP.gutter, vertical = 6.dp)) {
                    ErrorBanner(message) { store.clearError() }
                }
            }
            Box(Modifier.weight(1f)) {
                when {
                    showSetup -> SetupScreen(store) {
                        showSetup = false
                        selected = 0
                    }
                    showSettings -> SettingsScreen(store, scope) { showSettings = false }
                    selected == 0 -> ToolsScreen(store, scope) { showSetup = true }
                    selected == 1 -> DashboardScreen(store, scope)
                    selected == 2 -> ConnectionsScreen(store, scope)
                    selected == 3 -> PoliciesScreen(store, scope)
                    else -> DiagnosticsScreen(store, scope)
                }
            }
        }
    }
}
