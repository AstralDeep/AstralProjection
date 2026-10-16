// Exercises the audio observer lifecycle through its platform registration boundary, including
// active disposal, repeated start/stop, and queued callbacks after teardown.

package com.personalailabs.astraldeep.app.voice

import kotlin.test.Test
import kotlin.test.assertEquals

class VoiceAudioEnvironmentObserverTest {
    @Test
    fun closingAnActiveObserverReleasesThePlatformRegistrationExactlyOnce() {
        val environment = FakeEnvironment()
        val observer = VoiceAudioEnvironmentObserver(environment, {}, {})
        observer.start()
        observer.close()
        observer.close()
        observer.stop()
        observer.start()
        assertEquals(1, environment.starts)
        assertEquals(1, environment.stops)
    }

    @Test
    fun stoppedAndClosedObserversRejectQueuedPlatformCallbacks() {
        val environment = FakeEnvironment()
        val focusChanges = mutableListOf<Boolean>()
        var routeLosses = 0
        val observer = VoiceAudioEnvironmentObserver(environment, focusChanges::add, { routeLosses++ })
        observer.start()
        environment.focusChanged(true)
        environment.routeLost()
        observer.stop()
        environment.focusChanged(false)
        environment.routeLost()
        observer.close()
        environment.focusChanged(false)
        environment.routeLost()
        assertEquals(listOf(true), focusChanges)
        assertEquals(1, routeLosses)
        assertEquals(1, environment.stops)
    }

    @Test
    fun stoppingBeforeStartAndRestartingRetainsBalancedRegistrations() {
        val environment = FakeEnvironment()
        val observer = VoiceAudioEnvironmentObserver(environment, {}, {})
        observer.stop()
        observer.start()
        observer.start()
        observer.stop()
        observer.stop()
        observer.start()
        observer.close()
        assertEquals(2, environment.starts)
        assertEquals(2, environment.stops)
    }

    @Test
    fun callbacksFromAnEarlierRegistrationCannotInterruptARestartedObserver() {
        val environment = FakeEnvironment()
        val focusChanges = mutableListOf<Boolean>()
        val observer = VoiceAudioEnvironmentObserver(environment, focusChanges::add, {})
        observer.start()
        val staleFocusChanged = environment.focusChanged
        observer.stop()
        observer.start()
        staleFocusChanged(true)
        environment.focusChanged(false)
        assertEquals(listOf(false), focusChanges)
        observer.close()
    }

    private class FakeEnvironment : VoiceAudioEnvironment {
        var starts = 0
        var stops = 0
        var focusChanged: (Boolean) -> Unit = {}
        var routeLost: () -> Unit = {}

        override fun start(
            onAudioFocusChanged: (Boolean) -> Unit,
            onOutputRouteLost: () -> Unit,
        ) {
            starts++
            focusChanged = onAudioFocusChanged
            routeLost = onOutputRouteLost
        }

        override fun stop() {
            stops++
        }
    }
}
