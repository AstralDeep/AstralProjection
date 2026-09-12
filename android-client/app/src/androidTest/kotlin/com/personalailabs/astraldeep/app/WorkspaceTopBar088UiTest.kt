package com.personalailabs.astraldeep.app

import android.content.res.Configuration
import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.ui.AstralTopBar
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.core.chrome.ChromeMenuModel
import com.personalailabs.astraldeep.core.chrome.SignOutItem
import com.personalailabs.astraldeep.core.chrome.SurfaceRef
import com.personalailabs.astraldeep.core.chrome.TopBarControl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.io.File

class WorkspaceTopBar088UiTest {
    @get:Rule val rule = createComposeRule()
    private val export = TopBarControl("export", "workspace_action", "Export page", "download", operation = "export_canvas", context = "live_canvas")
    private val share = TopBarControl("share", "workspace_action", "Share page", "share", operation = "share_canvas", context = "live_canvas")
    private val model =
        ChromeMenuModel(
            2,
            listOf(
                TopBarControl("brand", "brand"),
                export,
                share,
                TopBarControl("pulse", "action", "Pulse digest", "sparkle", SurfaceRef("pulse")),
                TopBarControl("timeline", "action", "Workspace timeline", "history", SurfaceRef("workspace_timeline")),
                TopBarControl("settings", "menu", "Settings", "gear"),
            ),
            emptyList(),
            SignOutItem(),
        )

    @Test fun compact_actions_wrap_in_order_with_large_text_and_remain_tappable() = renderAndCheck(2f)

    @Test fun compact_actions_wrap_in_order_at_default_text_size() = renderAndCheck(1f)

    private fun renderAndCheck(scale: Float) {
        val selected = mutableListOf<String>()
        rule.setContent {
            val config = Configuration(LocalConfiguration.current).apply { screenWidthDp = 320 }
            CompositionLocalProvider(LocalConfiguration provides config, LocalDensity provides Density(LocalDensity.current.density, scale)) {
                AstralTheme {
                    Box(Modifier.width(320.dp)) {
                        AstralTopBar(model, listOf(export, share), { selected.add(it.operation!!) }, false, {}, {}, {}, { _, _ -> }, {})
                    }
                }
            }
        }
        val root = rule.onRoot().fetchSemanticsNode().boundsInRoot
        val labels = listOf("New chat", "Recent chats", "Export page", "Share page", "Pulse digest", "Workspace timeline", "Settings")
        val bounds =
            labels.map { label ->
                val node = rule.onNodeWithContentDescription(label)
                node.assertIsDisplayed()
                node.fetchSemanticsNode().boundsInRoot.also { assertTrue("$label within root", it.left >= root.left && it.right <= root.right && it.bottom <= root.bottom) }
            }
        val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
        bounds.forEach { assertTrue("48dp touch targets: $bounds at density $density", it.width >= 48 * density - 1 && it.height >= 48 * density - 1) }
        bounds.zipWithNext().forEach { (previous, next) ->
            assertTrue("canonical order survives wrap", next.top > previous.top || next.left >= previous.right)
        }
        assertTrue("controls wrap", bounds[5].top > bounds[0].top)
        val dir = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "workspace-088-synthetic").apply { mkdirs() }
        File(dir, "topbar-320-font-$scale.png").outputStream().use {
            rule.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
        }
        rule.onNodeWithContentDescription("Export page").performClick()
        rule.onNodeWithContentDescription("Share page").performClick()
        rule.runOnIdle { assertEquals(listOf("export_canvas", "share_canvas"), selected) }
    }
}
