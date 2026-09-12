package com.personalailabs.astraldeep.app.ui.theme

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Exact resting-state tokens from webrender/renderer.py and static/astral.css. */
internal object AstralWebStyle {
    val CardShape = RoundedCornerShape(10.dp)
    val MetricShape = RoundedCornerShape(12.dp)
    val SoftBorder = Color.White.copy(alpha = 0.07f)
    val MetricBorder = Color.White.copy(alpha = 0.05f)
    val Success = Color(0xFF22C55E)
    val Warning = Color(0xFFEAB308)
    val Error = Color(0xFFEF4444)
    val CardTitle = TextStyle(fontFamily = AstralSans, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, lineHeight = 24.sp)
    val ChartTitle = TextStyle(fontFamily = AstralSans, fontSize = 14.sp, fontWeight = FontWeight.Medium, lineHeight = 20.sp)
    val MetricTitle =
        TextStyle(fontFamily = AstralSans, fontSize = 12.sp, fontWeight = FontWeight.Medium, lineHeight = 16.sp, letterSpacing = 0.6.sp)
    val MetricValue =
        TextStyle(fontFamily = AstralSans, fontSize = 28.sp, fontWeight = FontWeight.Bold, lineHeight = 33.6.sp, letterSpacing = (-0.56).sp)
    val MetricSubtitle = TextStyle(fontFamily = AstralSans, fontSize = 12.sp, lineHeight = 16.sp)
    val NewChatLabel = TextStyle(fontFamily = AstralSans, fontSize = 14.sp, lineHeight = 20.sp)
}

@Composable
internal fun Modifier.astralCardSurface(): Modifier =
    astralSoftShadow(10f)
        .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.45f), AstralWebStyle.CardShape)
        .border(1.dp, AstralWebStyle.SoftBorder, AstralWebStyle.CardShape)
        .clip(AstralWebStyle.CardShape)

/** CSS outer shadows exclude the box interior, including translucent surfaces. */
internal fun Modifier.astralSoftShadow(cornerDp: Float): Modifier =
    drawWithCache {
        val radius = cornerDp.dp.toPx()
        val bounds = android.graphics.RectF(0f, 0f, size.width, size.height)
        val outline = android.graphics.Path().apply { addRoundRect(bounds, radius, radius, android.graphics.Path.Direction.CW) }
        val paint =
            android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                color = android.graphics.Color.BLACK
                setShadowLayer(2.dp.toPx(), 0f, 1.dp.toPx(), 0x40000000)
            }
        onDrawBehind {
            drawIntoCanvas { canvas ->
                val native = canvas.nativeCanvas
                val saved = native.save()
                native.clipOutPath(outline)
                native.drawRoundRect(bounds, radius, radius, paint)
                native.restoreToCount(saved)
            }
        }
    }
