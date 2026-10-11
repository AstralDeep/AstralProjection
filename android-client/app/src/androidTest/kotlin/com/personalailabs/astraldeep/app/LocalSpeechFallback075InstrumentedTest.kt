// Instrumented proof for the client-local speech gate: on a real Android image the engine probe
// reports platform-observed recognition and synthesis facts, and the readiness ladder turns any
// unsupported combination into a closed typed-fallback reason with no advertised capability.

package com.personalailabs.astraldeep.app

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.personalailabs.astraldeep.app.voice.AndroidLocalSpeechEngine
import com.personalailabs.astraldeep.app.voice.LocalSpeechReadiness
import com.personalailabs.astraldeep.core.protocol.LocalVoiceFrame
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LocalSpeechFallback075InstrumentedTest {
    @Test
    fun probeReportsPlatformFactsAndTheLadderKeepsUnsupportedCombinationsOnTypedFallback() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val engine = AndroidLocalSpeechEngine(context)
        val facts = engine.probe()
        assertTrue(facts.recognitionLocaleState in setOf("ready", "unknown"))
        assertTrue(facts.recognitionInstallation in setOf("ready", "unavailable"))
        assertTrue(facts.synthesisLocaleState in setOf("ready", "unknown"))

        val verdict = LocalSpeechReadiness.evaluate(facts)
        if (verdict.eligible) {
            val capability = requireNotNull(verdict.capability)
            assertEquals("authorized", capability.microphonePermission)
            assertTrue(facts.recognitionOnDevice)
            assertTrue(facts.synthesisEngineReady)
        } else {
            assertNull(verdict.capability)
            assertTrue(requireNotNull(verdict.reason) in LocalVoiceFrame.reasons)
        }
    }
}
