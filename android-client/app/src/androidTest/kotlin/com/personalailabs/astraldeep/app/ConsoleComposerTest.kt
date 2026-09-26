// Verifies active server-owned voice controls remain reachable beside the responsive message composer.
// Exercises keyboard submission and disabled-state boundaries without opening a microphone or network session.

package com.personalailabs.astraldeep.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.ui.ConsoleComposer
import com.personalailabs.astraldeep.app.ui.label
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.app.voice.VoiceUiState
import com.personalailabs.astraldeep.core.chrome.ChromeMenuModel
import com.personalailabs.astraldeep.core.protocol.VoiceComposerModel
import com.personalailabs.astraldeep.core.protocol.VoiceControl
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class ConsoleComposerTest {
    @get:Rule val rule = createComposeRule()

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun activeControlsWrapWithoutOverlappingAndHonorDisabledActions() {
        val context = InstrumentationRegistry.getInstrumentation().context
        val console = requireNotNull(ChromeMenuModel.fromJson(Json.parseToJsonElement(context.assets.open("console/chrome-console.json").bufferedReader().use { it.readText() }).jsonObject)?.console)
        val controls =
            listOf(
                "voice_session_end" to "End voice conversation",
                "voice_speech_stop" to "Stop speaking",
                "voice_speech_mute_set" to "Mute speech",
                "voice_visible_chat_update" to "Use this chat",
                "voice_sensitive_recap_request" to "Request recap",
            ).map { (action, label) -> VoiceControl(action, action, label, "microphone", true, action != "voice_sensitive_recap_request", false, false) }
        val composer =
            VoiceComposerModel(
                available = true, state = "listening", speechMuted = false, microphoneEnabled = true,
                foregroundActive = true, reason = "ready", outputLocale = "en-US", message = null,
                chatContextRevision = 1, appliedChatContextRevision = 1, chatContextSynced = true,
                sessionId = "00000000-0000-4000-8000-000000000001", generation = 1, mediaGrantRevision = 1,
                visibleChatId = "00000000-0000-4000-8000-000000000002", foregroundTurnId = null,
                ownerDevice = null, idleExpiresAt = null, controls = controls,
            )
        var width by mutableStateOf(320)
        var fontScale by mutableStateOf(1f)
        var readOnly by mutableStateOf(false)
        var draft by mutableStateOf("")
        var sent = 0
        var attached = 0
        val invoked = mutableListOf<String>()
        rule.setContent {
            BoxWithConstraints {
                val density = minOf(1f, constraints.maxWidth / width.toFloat())
                CompositionLocalProvider(LocalDensity provides Density(density, fontScale)) {
                    AstralTheme {
                        Box(Modifier.size(width.dp, 400.dp).testTag("composer-root")) {
                            ConsoleComposer(
                                draft, { draft = it }, readOnly, VoiceUiState(composer, "listening"),
                                { invoked += it.action }, { attached++ }, { sent++ }, draft.isNotBlank(), console, false, {},
                            )
                        }
                    }
                }
            }
        }
        for (viewport in listOf(320, 390, 768, 1440)) {
            rule.runOnIdle {
                width = viewport
                fontScale = if (viewport == 320) 1.6f else 1f
            }
            val root = rule.onNodeWithTag("composer-root").fetchSemanticsNode().boundsInRoot
            val field = rule.onNodeWithTag("chat-input").fetchSemanticsNode().boundsInRoot
            val bounds =
                (controls.map { "voice-control-${it.action}" } + "composer-send").map { tag ->
                    rule.onNodeWithTag(tag).assertIsDisplayed().fetchSemanticsNode().boundsInRoot
                }
            bounds.forEach { target ->
                assertTrue("Control outside viewport: $target in $root", target.left >= root.left && target.right <= root.right && target.bottom <= root.bottom)
                assertTrue("Control overlaps message field", !target.overlaps(field))
            }
            bounds.forEachIndexed { index, target -> bounds.drop(index + 1).forEach { assertTrue("Controls overlap", !target.overlaps(it)) } }
        }
        rule.onNodeWithTag("voice-control-voice_speech_stop").performClick()
        assertEquals(listOf("voice_speech_stop"), invoked)
        rule.onNodeWithTag("voice-control-voice_sensitive_recap_request").assertIsNotEnabled().performClick()
        assertEquals(1, invoked.size)
        rule.onNodeWithTag("composer-send").assertIsNotEnabled()
        rule.onNodeWithTag("chat-input").performTextInput("Roll six dice")
        rule.onNodeWithTag("chat-input").performKeyInput {
            keyDown(Key.Enter)
            keyUp(Key.Enter)
        }
        assertEquals(1, sent)
        rule.runOnIdle { readOnly = true }
        rule.onNodeWithTag("chat-input").assertIsNotEnabled()
        rule.onNodeWithTag("composer-send").assertIsNotEnabled().performClick()
        rule.onNodeWithContentDescription(console.label("attach")).assertIsNotEnabled().performClick()
        rule.onNodeWithContentDescription(console.label("more")).assertIsNotEnabled()
        controls.forEach { rule.onNodeWithTag("voice-control-${it.action}").assertIsNotEnabled().performClick() }
        assertEquals(1, sent)
        assertEquals(0, attached)
        assertEquals(1, invoked.size)
    }
}
