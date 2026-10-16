// Verifies that Android TTS progress reaches LocalVoiceRuntime only for the current utterance,
// once per transition and through the owner dispatcher, including queued callbacks after teardown.

package com.personalailabs.astraldeep.app.voice

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class LocalSpeechUtteranceTest {
    @Test
    fun progressRunsOnTheOwnerDispatcherAndCompletesOnlyOnce() {
        val rig = CallbackRig()
        rig.listener.onStart("current")
        rig.listener.onStart("current")
        rig.listener.onDone("current")
        rig.listener.onError("current", 3)
        assertTrue(rig.events.isEmpty())
        rig.drain()
        assertEquals(listOf("started", "released", "done:true"), rig.events)
        rig.listener.onStart("current")
        rig.drain()
        assertEquals(listOf("started", "released", "done:true"), rig.events)
    }

    @Test
    fun unrelatedUtteranceCannotStartFinishOrClearTheCurrentListener() {
        val rig = CallbackRig()
        rig.listener.onStart("previous")
        rig.listener.onDone("previous")
        rig.listener.onError("previous", 3)
        rig.listener.onError(null)
        rig.drain()
        assertTrue(rig.events.isEmpty())
        rig.listener.onStart("current")
        rig.listener.onDone("current")
        rig.drain()
        assertEquals(listOf("started", "released", "done:true"), rig.events)
    }

    @Test
    fun queuedCallbacksCannotAffectAStoppedOrReplacedOwner() {
        val rig = CallbackRig()
        rig.listener.onStart("current")
        rig.listener.onDone("current")
        rig.current = false
        rig.drain()
        rig.listener.onError("current", 3)
        rig.drain()
        assertTrue(rig.events.isEmpty())
    }

    @Test
    fun currentErrorsAndUnexpectedPlatformStopFailOnce() {
        for (signal in listOf("legacy", "error", "stop")) {
            val rig = CallbackRig()
            when (signal) {
                "legacy" -> rig.listener.onError("current")
                "error" -> rig.listener.onError("current", 3)
                else -> rig.listener.onStop("current", true)
            }
            rig.listener.onDone("current")
            rig.drain()
            assertEquals(listOf("released", "done:false"), rig.events)
        }
    }

    private class CallbackRig {
        var current = true
        val events = mutableListOf<String>()
        private val pending = ArrayDeque<() -> Unit>()
        val listener =
            LocalSpeechUtterance(
                "current",
                { pending.addLast(it) },
                { current },
                { events.add("started") },
                { events.add("done:$it") },
                { events.add("released") },
            )

        fun drain() {
            while (pending.isNotEmpty()) pending.removeFirst().invoke()
        }
    }
}
