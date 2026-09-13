package com.personalailabs.astraldeep.app

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import com.personalailabs.astraldeep.app.ui.SurfaceScreen
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** Exercise the shipping surface/recursive renderer, without an authenticated app graph. */
class WorkSurfaceRead088UiTest {
    @get:Rule val rule = createComposeRule()

    private fun text(
        content: String,
        variant: String = "body",
    ): Component =
        Component(
            "text",
            "excerpt",
            buildJsonObject {
                put("type", "text")
                put("content", content)
                put("variant", variant)
            },
            emptyList(),
        )

    private fun card(
        title: String,
        content: String,
    ): Component =
        Component(
            "card",
            "source",
            buildJsonObject {
                put("type", "card")
                put("title", title)
            },
            listOf(text(content)),
        )

    private fun assertLiteral(content: String) {
        val node = rule.onNodeWithText(content, useUnmergedTree = true).fetchSemanticsNode()
        val rendered = node.config[SemanticsProperties.Text].single()
        assertEquals(content, rendered.text)
        assertTrue(rendered.getLinkAnnotations(0, rendered.length).isEmpty())
    }

    @Test
    fun work_nested_source_title_and_excerpt_are_complete_literal_inert_text() {
        val title = "**Source** [title](https://example.org/source) <b>literal</b>"
        val excerpt = "\n# Unmodified excerpt\n* original * _text_ `code`\n[URL](https://example.org/evidence)\n<b>literal</b>\n"
        rule.setContent {
            AstralTheme {
                val renderer = Renderer(Emit { _, _ -> error("Passive source text emitted an action") }).registerAllRenderers()
                SurfaceScreen(Inbound.ChromeSurface("work", "Work", listOf(card(title, excerpt))), "work", renderer, {})
            }
        }
        assertLiteral(title)
        assertLiteral(excerpt)
    }

    @Test
    fun work_keeps_every_character_of_a_maximum_sized_excerpt() {
        val excerpt = "**[" + "x".repeat(8186) + "]**"
        assertEquals(8192, excerpt.toByteArray(Charsets.UTF_8).size)
        rule.setContent {
            AstralTheme {
                val renderer = Renderer(Emit { _, _ -> }).registerAllRenderers()
                SurfaceScreen(Inbound.ChromeSurface("work", "Work", listOf(text(excerpt))), "work", renderer, {})
            }
        }
        assertLiteral(excerpt)
    }

    @Test
    fun leaving_work_restores_ordinary_markdown_on_the_same_renderer() {
        val surfaceKey = mutableStateOf("work")
        val renderer = Renderer(Emit { _, _ -> }).registerAllRenderers()
        val components = listOf(card("**Source title**", "**Excerpt text**"))
        rule.setContent {
            AstralTheme {
                val surface = Inbound.ChromeSurface(surfaceKey.value, "Surface", components)
                SurfaceScreen(surface, surfaceKey.value, renderer, {})
            }
        }
        assertLiteral("**Source title**")
        assertLiteral("**Excerpt text**")
        rule.runOnIdle { surfaceKey.value = "theme" }
        rule.onNodeWithText("Source title").assertIsDisplayed()
        rule.onNodeWithText("Excerpt text").assertIsDisplayed()
        rule.runOnIdle { surfaceKey.value = "work" }
        assertLiteral("**Source title**")
        assertLiteral("**Excerpt text**")
    }

    @Test
    fun work_preserves_server_heading_caption_and_body_styles() {
        var muted = Color.Unspecified
        var foreground = Color.Unspecified
        rule.setContent {
            AstralTheme {
                muted = MaterialTheme.colorScheme.onSurfaceVariant
                foreground = MaterialTheme.colorScheme.onSurface
                val renderer = Renderer(Emit { _, _ -> }).registerAllRenderers()
                val components = listOf(text("Work result", "h1"), text("Page evidence", "h2"), text("Selected excerpts", "h3"), text("Source attribution", "caption"), text("Exact evidence"))
                SurfaceScreen(Inbound.ChromeSurface("work", "Work", components), "work", renderer, {})
            }
        }
        val heading = rule.onNodeWithText("Selected excerpts", useUnmergedTree = true).fetchSemanticsNode()
        assertTrue(heading.config.contains(SemanticsProperties.Heading))

        fun style(content: String) =
            mutableListOf<TextLayoutResult>().also { results ->
                rule.onNodeWithText(content, useUnmergedTree = true)
                    .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(results) }
            }.single().layoutInput.style
        for (headingText in listOf("Work result", "Page evidence")) {
            assertTrue(rule.onNodeWithText(headingText, useUnmergedTree = true).fetchSemanticsNode().config.contains(SemanticsProperties.Heading))
        }
        assertEquals(24.sp, style("Work result").fontSize)
        assertEquals(32.sp, style("Work result").lineHeight)
        assertEquals(FontWeight.Bold, style("Work result").fontWeight)
        assertEquals(20.sp, style("Page evidence").fontSize)
        assertEquals(28.sp, style("Page evidence").lineHeight)
        assertEquals(FontWeight.SemiBold, style("Page evidence").fontWeight)
        assertEquals(18.sp, style("Selected excerpts").fontSize)
        assertEquals(28.sp, style("Selected excerpts").lineHeight)
        assertEquals(FontWeight.Medium, style("Selected excerpts").fontWeight)
        assertEquals(12.sp, style("Source attribution").fontSize)
        assertEquals(16.sp, style("Source attribution").lineHeight)
        assertEquals(muted, style("Source attribution").color)
        assertEquals(14.sp, style("Exact evidence").fontSize)
        assertEquals(22.75.sp, style("Exact evidence").lineHeight)
        assertEquals(foreground, style("Exact evidence").color)
    }
}
