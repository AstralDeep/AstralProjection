package com.personalailabs.astraldeep.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.personalailabs.astraldeep.app.ui.InputBar
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.app.voice.VoiceTerminalNotice
import com.personalailabs.astraldeep.app.voice.VoiceTerminalNoticeKind
import com.personalailabs.astraldeep.app.voice.VoiceUiState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class ComposerStyle088InstrumentedTest {
    @get:Rule val rule = createComposeRule()

    @Test
    fun narrowComposerKeepsSendAtRightAndRetainsEditingAndReadOnlyRules() {
        var text by mutableStateOf("")
        var readOnly by mutableStateOf(false)
        var sent: String? = null
        rule.setContent {
            AstralTheme {
                Surface(color = MaterialTheme.colorScheme.background) {
                    Box(Modifier.width(320.dp)) {
                        InputBar(
                            text, { text = it }, emptyList(), readOnly, VoiceUiState(), { _, _ -> },
                            { sent = it }, { _, _, _ -> }, {}, {},
                        )
                    }
                }
            }
        }
        rule.onNodeWithTag("composer-send").assertIsNotEnabled()
        rule.onNodeWithTag("chat-input").performTextInput("First line\nSecond line")
        assertEquals(null, sent)
        val send = rule.onNodeWithTag("composer-send").fetchSemanticsNode().boundsInRoot
        val attach = rule.onNodeWithContentDescription("Attach files").fetchSemanticsNode().boundsInRoot
        val input = rule.onNodeWithTag("chat-input").fetchSemanticsNode().boundsInRoot
        assertTrue(send.left > attach.right)
        assertTrue(kotlin.math.abs(send.right - input.right) <= 1f)
        rule.onNodeWithTag("composer-send").performClick()
        assertEquals("First line\nSecond line", sent)
        assertEquals("", text)
        rule.runOnIdle {
            text = "Retained draft"
            readOnly = true
        }
        rule.onNodeWithTag("chat-input").assertIsNotEnabled()
        rule.onNodeWithTag("composer-send").assertIsNotEnabled()
        rule.onNodeWithText("Retained draft").assertIsDisplayed()
    }

    @Test
    fun offComposerRetainsTerminalFailureAndSpeechNoticesWithoutOrdinaryFeedback() {
        var notice by mutableStateOf(
            VoiceTerminalNotice(
                VoiceTerminalNoticeKind.REQUEST_DID_NOT_COMPLETE,
                "Voice request did not complete",
                null,
                "Typed chat is still available.",
            ),
        )
        rule.setContent {
            AstralTheme {
                InputBar(
                    "", {}, emptyList(), false, VoiceUiState(terminalNotice = notice),
                    { _, _ -> }, {}, { _, _, _ -> }, {}, {},
                )
            }
        }
        rule.onNodeWithTag("voice-terminal-notice").assertIsDisplayed()
        rule.onNodeWithText("Voice request did not complete", useUnmergedTree = true).assertIsDisplayed()
        rule.runOnIdle {
            notice =
                VoiceTerminalNotice(
                    VoiceTerminalNoticeKind.TEXT_RESULT_AVAILABLE,
                    "Speech playback failed", null, "The text result remains available.", speechUnavailable = true,
                )
        }
        rule.onNodeWithTag("voice-terminal-notice").assertIsDisplayed()
        rule.onNodeWithText("The text result remains available.", useUnmergedTree = true).assertIsDisplayed()
    }

    @Test
    fun largeTextWrapsControlsAndKeepsWarningsAndDraftVisible() {
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 2f)) {
                AstralTheme {
                    Surface(color = MaterialTheme.colorScheme.background) {
                        Box(Modifier.width(320.dp)) {
                            InputBar(
                                "Review this", {}, emptyList(), false,
                                VoiceUiState(phase = "error", reason = "permission_denied", message = "Microphone permission was denied."),
                                { _, _ -> }, {}, { _, _, _ -> }, {}, {}, startView = true,
                            )
                        }
                    }
                }
            }
        }
        rule.onNodeWithText("Review this").assertIsDisplayed()
        rule.onNodeWithText("Microphone permission was denied.").assertIsDisplayed()
        val send = rule.onNodeWithTag("composer-send").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val attach = rule.onNodeWithContentDescription("Attach files").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val background = rule.onNodeWithContentDescription("Run in background").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        assertTrue(send.left >= attach.right)
        assertTrue(send.left >= background.right)
    }
}
