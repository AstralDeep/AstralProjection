// Verifies measured viewport updates through the real Compose host and WebSocket transport.
// Runtime monitor checks use Android services and restore the system animation preference after each trial.

package com.personalailabs.astraldeep.app

import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.app.transport.RuntimeDeviceMonitor
import com.personalailabs.astraldeep.app.transport.runtimeVoiceCapability
import com.personalailabs.astraldeep.app.ui.AppViewModel
import com.personalailabs.astraldeep.app.ui.DeviceObservation
import com.personalailabs.astraldeep.app.voice.LiveKitVoiceGrant
import com.personalailabs.astraldeep.app.voice.OkHttpVoiceControlApi
import com.personalailabs.astraldeep.app.voice.VoiceMediaClient
import com.personalailabs.astraldeep.app.voice.VoiceMediaEvent
import com.personalailabs.astraldeep.app.voice.VoiceSessionController
import com.personalailabs.astraldeep.core.protocol.VoiceAnnouncementMedia
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

class DeviceObservationTest {
    @get:Rule val rule = createComposeRule()

    @Test fun viewportChangesAndHostRemountPreserveConnectionAndDraft() {
        val frames = CopyOnWriteArrayList<JsonObject>()
        val server = MockWebServer()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(
                object : WebSocketListener() {
                    override fun onOpen(
                        webSocket: WebSocket,
                        response: Response,
                    ) = Unit

                    override fun onMessage(
                        webSocket: WebSocket,
                        text: String,
                    ) {
                        frames += Json.parseToJsonElement(text).jsonObject
                    }
                },
            ),
        )
        server.start()
        val voice =
            VoiceSessionController(
                OkHttpVoiceControlApi(server.url("/").toString()),
                object : VoiceMediaClient {
                    override val events = emptyFlow<VoiceMediaEvent>()

                    override suspend fun connect(grant: LiveKitVoiceGrant) = error("No voice session was requested")

                    override suspend fun setMicrophoneEnabled(enabled: Boolean) = error("No microphone was requested")

                    override suspend fun queueAnnouncement(value: VoiceAnnouncementMedia): Boolean = error("No speech was requested")

                    override fun interruptPlayout() = Unit

                    override fun disconnect() = Unit
                },
            )
        val vm = AppViewModel(OrchestratorClient(server.url("/ws").toString().replace("http:", "ws:")), AstralRest(server.url("/").toString()), voiceController = voice)
        var width by mutableStateOf(300)
        var visible by mutableStateOf(true)
        try {
            rule.setContent {
                Box(Modifier.size(width.dp, 360.dp)) {
                    if (visible) DeviceObservation(vm, "synthetic", listOf("text")) {}
                }
            }
            rule.waitUntil(10000) { frames.any { it["type"]?.jsonPrimitive?.content == "register_ui" } }
            val registration = frames.first { it["type"]?.jsonPrimitive?.content == "register_ui" }
            assertEquals("300", registration.getValue("device").jsonObject.getValue("viewport_width").jsonPrimitive.content)
            assertEquals("console/v2", registration.getValue("device").jsonObject.getValue("console_contract").jsonPrimitive.content)
            val connection = vm.state.value.connectionGeneration
            rule.runOnIdle {
                vm.updateComposerDraft("Keep this draft")
                width = 230
            }
            rule.waitUntil(10000) {
                frames.any { it["action"]?.jsonPrimitive?.content == "update_device" && it["payload"]?.jsonObject?.get("device")?.jsonObject?.get("viewport_width")?.jsonPrimitive?.content == "230" }
            }
            rule.runOnIdle { visible = false }
            rule.runOnIdle { assertFalse(voice.preparationIsCurrent(voice.preparationToken)) }
            rule.runOnIdle { visible = true }
            rule.waitForIdle()
            rule.runOnIdle { assertTrue(voice.preparationIsCurrent(voice.preparationToken)) }
            assertEquals(connection, vm.state.value.connectionGeneration)
            assertEquals("Keep this draft", vm.state.value.composerDraft)
            assertEquals(1, server.requestCount)
            assertEquals(1, frames.count { it["type"]?.jsonPrimitive?.content == "register_ui" })
            assertFalse(frames.any { it["action"]?.jsonPrimitive?.content in setOf("load_chat", "new_chat") })
        } finally {
            rule.runOnIdle {
                visible = false
                vm.clearConversationForSignOut()
                voice.close()
            }
            server.shutdown()
        }
    }

    @Test fun runtimeFactsRefreshFromServicesAndStopAfterDisposal() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context: Context = instrumentation.targetContext
        val previous = Settings.Global.getString(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE)

        fun motion(value: String?) {
            val command = if (value == null) "settings delete global animator_duration_scale" else "settings put global animator_duration_scale $value"
            instrumentation.uiAutomation.executeShellCommand(command).use { descriptor ->
                android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { it.readBytes() }
            }
        }
        val monitor = RuntimeDeviceMonitor(context)
        try {
            rule.runOnIdle {
                monitor.start()
                monitor.start()
            }
            assertEquals(context.packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN), monitor.facts.value.hasTouch)
            assertEquals(runtimeVoiceCapability(context), monitor.facts.value.voice)
            motion("0")
            rule.waitUntil(5000) { monitor.facts.value.reducedMotion }
            motion("1")
            rule.waitUntil(5000) { !monitor.facts.value.reducedMotion }
            val final = monitor.facts.value
            rule.runOnIdle {
                monitor.close()
                monitor.close()
                monitor.start()
            }
            motion("0")
            rule.runOnIdle { monitor.refresh() }
            assertEquals(final, monitor.facts.value)
            assertTrue(final.connectionType in setOf("wifi", "cellular", "ethernet", "unknown"))
        } finally {
            rule.runOnIdle { monitor.close() }
            motion(previous)
        }
    }
}
