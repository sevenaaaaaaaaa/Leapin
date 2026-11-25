package app.leapin.mobile.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Same palette as the desktop and iOS clients: one signal colour, warm neutrals. */
private val AccentLight = Color(0xFFC63A12)
private val AccentDark = Color(0xFFFF7A4D)
private val AccentFillLight = Color(0xFFB83510)
private val AccentFillDark = Color(0xFFC2410F)

object LP {
    val accent: Color @Composable get() = if (isSystemInDarkTheme()) AccentDark else AccentLight
    val accentFill: Color @Composable get() = if (isSystemInDarkTheme()) AccentFillDark else AccentFillLight
    val mint: Color @Composable get() = if (isSystemInDarkTheme()) Color(0xFF35D19B) else Color(0xFF0C7A55)
    val amber: Color @Composable get() = if (isSystemInDarkTheme()) Color(0xFFE8B04A) else Color(0xFF8F5E07)
    val danger: Color @Composable get() = if (isSystemInDarkTheme()) Color(0xFFFF6B74) else Color(0xFFB32636)
    val violet: Color @Composable get() = if (isSystemInDarkTheme()) Color(0xFFB0A3FF) else Color(0xFF5446B8)

    /** v5 ink：每屏最多一个焦点带，与桌面 / iOS 同一组值。 */
    val ink: Color @Composable get() = if (isSystemInDarkTheme()) Color(0xFF1C1C1F) else Color(0xFF19191B)
    val onInk: Color @Composable get() = Color(0xFFF4EFE6)
    val onInkSecondary: Color @Composable get() = Color(0xFFF4EFE6).copy(alpha = 0.62f)

    val canvas: Color @Composable get() = MaterialTheme.colorScheme.background
    val panel: Color @Composable get() = MaterialTheme.colorScheme.surface
    val text: Color @Composable get() = MaterialTheme.colorScheme.onSurface
    val textSecondary: Color @Composable get() = MaterialTheme.colorScheme.onSurfaceVariant
    val textTertiary: Color @Composable get() = MaterialTheme.colorScheme.outline
    val stroke: Color @Composable get() = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)

    val radius = 14.dp
    val gutter = 16.dp
}

private val LightColors = lightColorScheme(
    primary = AccentFillLight,
    onPrimary = Color.White,
    background = Color(0xFFF6F4EF),
    onBackground = Color(0xFF16150F),
    surface = Color(0xFFFCFBF8),
    onSurface = Color(0xFF16150F),
    surfaceVariant = Color(0xFFFFFFFF),
    onSurfaceVariant = Color(0xFF5F5C53),
    outline = Color(0xFF6F6B60),
    outlineVariant = Color(0xFFDDD9CF),
    error = Color(0xFFB32636),
)

private val DarkColors = darkColorScheme(
    primary = AccentFillDark,
    onPrimary = Color.White,
    background = Color(0xFF101012),
    onBackground = Color(0xFFF3F1EA),
    surface = Color(0xFF151517),
    onSurface = Color(0xFFF3F1EA),
    surfaceVariant = Color(0xFF1F1F22),
    onSurfaceVariant = Color(0xFFA6A39A),
    outline = Color(0xFF87847B),
    outlineVariant = Color(0xFF33333A),
    error = Color(0xFFFF6B74),
)

@Composable
fun LeapinTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) DarkColors else LightColors,
        typography = MaterialTheme.typography,
        content = content
    )
}

// MARK: - Building blocks

@Composable
fun Panel(
    title: String? = null,
    subtitle: String? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        color = LP.panel,
        shape = RoundedCornerShape(LP.radius),
        border = androidx.compose.foundation.BorderStroke(1.dp, LP.stroke),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (title != null) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = LP.text)
                    if (subtitle != null) {
                        Text(subtitle, fontSize = 11.sp, color = LP.textTertiary)
                    }
                }
            }
            content()
        }
    }
}

@Composable
fun Stat(label: String, value: String, unit: String? = null, tint: Color = LP.text) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(label, fontSize = 11.sp, color = LP.textTertiary)
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(value, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = tint)
            if (unit != null) Text(unit, fontSize = 11.sp, color = LP.textTertiary)
        }
    }
}

@Composable
fun Pill(text: String, tint: Color, filled: Boolean = false) {
    Surface(
        color = if (filled) tint else tint.copy(alpha = 0.14f),
        shape = RoundedCornerShape(5.dp),
    ) {
        Text(
            text,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = if (filled) Color.White else tint,
            modifier = Modifier.padding(horizontal = 7.dp, vertical = 3.dp)
        )
    }
}

@Composable
fun KeyValue(key: String, value: String, mono: Boolean = false) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Text(key, fontSize = 12.sp, color = LP.textTertiary)
        Text(
            value,
            fontSize = 12.sp,
            color = LP.textSecondary,
            fontFamily = if (mono) FontFamily.Monospace else FontFamily.Default,
            modifier = Modifier.weight(1f),
            textAlign = androidx.compose.ui.text.style.TextAlign.End,
        )
    }
}

@Composable
fun MonoText(text: String, size: Int = 11, color: Color = LP.textTertiary) {
    Text(text, fontSize = size.sp, color = color, fontFamily = FontFamily.Monospace)
}

@Composable
fun PageBackground(content: @Composable () -> Unit) {
    Surface(color = LP.canvas, modifier = Modifier.fillMaxWidth()) { content() }
}

fun formatBytes(value: Long): String {
    val units = listOf("B", "KB", "MB", "GB", "TB")
    var size = value.toDouble()
    var index = 0
    while (size >= 1024 && index < units.lastIndex) {
        size /= 1024
        index++
    }
    return if (index == 0) "${size.toInt()} ${units[index]}"
           else String.format("%.1f %s", size, units[index])
}

fun formatDuration(seconds: Double): String = when {
    seconds < 60 -> "${seconds.toInt()} 秒"
    seconds < 3600 -> "${(seconds / 60).toInt()} 分钟"
    else -> {
        val hours = (seconds / 3600).toInt()
        val minutes = ((seconds % 3600) / 60).toInt()
        if (minutes == 0) "$hours 小时" else "$hours 小时 $minutes 分"
    }
}

fun formatMs(value: Double): String =
    if (value >= 1000) String.format("%.2f s", value / 1000) else String.format("%.0f ms", value)

fun formatAgo(timestamp: Long?): String {
    if (timestamp == null) return "尚未刷新"
    val seconds = (System.currentTimeMillis() - timestamp) / 1000
    return when {
        seconds < 3 -> "刚刚"
        seconds < 60 -> "$seconds 秒前"
        seconds < 3600 -> "${seconds / 60} 分钟前"
        else -> "${seconds / 3600} 小时前"
    }
}

/** Inline error strip shown above every tab. */
@Composable
fun ErrorBanner(message: String, onDismiss: () -> Unit) {
    Surface(
        color = LP.panel,
        shape = RoundedCornerShape(10.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, LP.danger.copy(alpha = 0.35f)),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            Modifier.padding(10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Text("!", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = LP.danger)
            Text(message, fontSize = 12.sp, color = LP.text, modifier = Modifier.weight(1f))
            Text(
                "×",
                fontSize = 14.sp,
                color = LP.textTertiary,
                modifier = Modifier.padding(start = 4.dp).clickable { onDismiss() },
            )
        }
    }
}
