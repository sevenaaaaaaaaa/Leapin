package app.leapin.mobile.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * v5 的「一条路」：全产品唯一的装饰几何。
 * 与桌面 RouteLine、iOS RouteLine 同一套画法与同一组色值。
 */
@Composable
fun RouteLine(nodes: List<String>, current: Int, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
        nodes.forEachIndexed { index, name ->
            Column(
                modifier = Modifier.weight(1f),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    if (index == current) {
                        Box(Modifier.size(16.dp).background(LP.accent.copy(alpha = 0.26f), CircleShape))
                    }
                    Box(
                        Modifier
                            .size(7.dp)
                            .background(if (index == current) LP.accent else LP.onInkSecondary, CircleShape)
                    )
                }
                Text(
                    name,
                    fontSize = 13.sp,
                    color = if (index == current) LP.onInk else LP.onInkSecondary,
                    maxLines = 1,
                )
            }
            if (index < nodes.lastIndex) {
                Box(
                    Modifier
                        .weight(0.55f)
                        .padding(top = 8.dp)
                        .height(1.dp)
                        .background(LP.onInkSecondary.copy(alpha = 0.32f))
                )
            }
        }
    }
}

/** 墨色焦点带：一条路 + 事实 + 一个主操作。 */
@Composable
fun FocusBand(eyebrow: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Surface(
        color = LP.ink,
        shape = RoundedCornerShape(LP.radius),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            Modifier.padding(horizontal = 18.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            if (eyebrow != null) {
                Text(
                    eyebrow,
                    fontSize = 11.sp,
                    letterSpacing = 0.8.sp,
                    color = LP.onInkSecondary,
                    fontFamily = FontFamily.Monospace,
                )
            }
            content()
        }
    }
}

/** 一条事实：11 标签 + 20 mono 数值。 */
@Composable
fun Fact(label: String, value: String, mono: Boolean = true, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(label, fontSize = 11.sp, color = LP.onInkSecondary, fontFamily = FontFamily.Monospace)
        Text(
            value,
            fontSize = if (mono) 20.sp else 13.sp,
            fontWeight = if (mono) FontWeight.SemiBold else FontWeight.Medium,
            color = LP.onInk,
            fontFamily = if (mono) FontFamily.Monospace else FontFamily.Default,
            maxLines = 1,
        )
    }
}

/** ink 底上的主按钮：纸色底、墨色字。一屏只有一个。 */
@Composable
fun OnInkButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        onClick = onClick,
        color = LP.onInk,
        shape = RoundedCornerShape(8.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        Box(Modifier.padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
            Text(
                text,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = LP.ink,
            )
        }
    }
}

/** v5 页头：28 标题 + 一句状态。 */
@Composable
fun PageHeader(title: String, status: String? = null) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(title, fontSize = 28.sp, fontWeight = FontWeight.SemiBold, color = LP.text)
        if (status != null) {
            Text(status, fontSize = 13.sp, color = LP.textSecondary)
        }
    }
}
