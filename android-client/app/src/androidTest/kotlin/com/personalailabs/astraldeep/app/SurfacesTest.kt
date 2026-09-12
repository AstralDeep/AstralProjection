package com.personalailabs.astraldeep.app

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.personalailabs.astraldeep.app.rest.AuditEvent
import com.personalailabs.astraldeep.app.ui.AgentsScreen
import com.personalailabs.astraldeep.app.ui.AuditScreen
import com.personalailabs.astraldeep.app.ui.HistoryScreen
import com.personalailabs.astraldeep.core.protocol.Agent
import com.personalailabs.astraldeep.core.protocol.ChatSummary
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

/** US4 (T048): the management surfaces render their data. */
class SurfacesTest {
    @get:Rule val rule = createComposeRule()

    @Test
    fun agents_screen_lists_agent() {
        rule.setContent {
            AgentsScreen(
                agents = listOf(Agent("a1", "Weather", "Forecasts", false, mapOf("get_weather" to true))),
                loading = false,
                onToggleAgent = { _, _ -> },
                onToggleTool = { _, _, _ -> },
                onEnableRecommended = {},
            )
        }
        // AgentCard prefixes the name with an expand caret ("▶ Weather"), so match
        // the substring (feature 044: this instrumented test was nightly-only and
        // its exact-match assertion had been silently broken since the 043 caret).
        rule.onNodeWithText("Weather", substring = true).assertIsDisplayed()
    }

    @Test
    fun history_screen_lists_chat() {
        rule.setContent {
            HistoryScreen(listOf(ChatSummary("c1", "My chat")), loading = false, onOpen = {})
        }
        rule.onNodeWithText("My chat").assertIsDisplayed()
    }

    @Test
    fun history_previews_distinguish_same_title_chats_and_open_exact_owner_row() {
        var opened: String? = null
        rule.setContent {
            HistoryScreen(
                listOf(
                    ChatSummary("first", "New Chat", preview = "Earlier result"),
                    ChatSummary("second", "New Chat", preview = "\n\nAlpha = 2\tand\nBeta = 5", hasSavedComponents = true),
                ),
                loading = false,
                onOpen = { opened = it },
            )
        }
        rule.onNodeWithText("Earlier result").assertIsDisplayed()
        rule.onNodeWithText("Alpha = 2 and Beta = 5").assertIsDisplayed().performClick()
        rule.runOnIdle { assertEquals("second", opened) }
    }

    @Test
    fun history_normalizes_blank_title_without_interpreting_preview_markup() {
        rule.setContent {
            HistoryScreen(
                listOf(ChatSummary("plain", " \t\n", preview = "\n<script>plain text</script>\r\n")),
                loading = false,
                onOpen = {},
                title = "Saved conversations",
            )
        }
        rule.onNodeWithText("SAVED CONVERSATIONS").assertIsDisplayed()
        rule.onNodeWithText("Untitled chat").assertIsDisplayed()
        rule.onNodeWithText("<script>plain text</script>").assertIsDisplayed()
    }

    @Test
    fun audit_screen_shows_event() {
        rule.setContent {
            AuditScreen(listOf(AuditEvent("e1", "auth", "login", "success", "2026-06-30")), loading = false)
        }
        rule.onNodeWithText("auth · login").assertIsDisplayed()
    }
}
