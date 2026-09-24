// Shimmering placeholder composables shown while the canvas or a list surface (agents/history/audit) is
// loading, used by CanvasHost and Screens.kt until the first SDUI content commits.

package com.personalailabs.astraldeep.app.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

private val SkeletonShade = Color(0xFF313A5C)

@Composable
internal fun shimmerAlpha(): Float {
    val transition = rememberInfiniteTransition(label = "skeleton")
    val alpha by transition.animateFloat(
        initialValue = 0.5f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(850), RepeatMode.Reverse),
        label = "alpha",
    )
    return alpha
}

@Composable
internal fun SkeletonBlock(
    alpha: Float,
    heightDp: Int,
    widthFraction: Float = 1f,
) {
    Box(
        modifier =
            Modifier
                .fillMaxWidth(widthFraction)
                .heightIn(min = heightDp.dp, max = heightDp.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(SkeletonShade.copy(alpha = alpha)),
    )
}

@Composable
internal fun SkeletonCanvas(modifier: Modifier = Modifier) {
    val alpha = shimmerAlpha()
    Column(modifier = modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        SkeletonBlock(alpha, 28, 0.55f)
        SkeletonBlock(alpha, 120, 1f)
        SkeletonBlock(alpha, 92, 1f)
        SkeletonBlock(alpha, 150, 1f)
        SkeletonBlock(alpha, 40, 0.4f)
    }
}

@Composable
internal fun SkeletonList(
    modifier: Modifier = Modifier,
    rows: Int = 6,
    rowHeightDp: Int = 74,
) {
    val alpha = shimmerAlpha()
    Column(
        modifier = modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        repeat(rows) { SkeletonBlock(alpha, rowHeightDp, 1f) }
    }
}
