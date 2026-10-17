// Delivers only the current Android TTS utterance to LocalVoiceRuntime on its owner dispatcher.
// AndroidLocalSpeechEngine invalidates ownership before stopping or replacing synthesis.

package com.personalailabs.astraldeep.app.voice

import android.speech.tts.UtteranceProgressListener

internal class LocalSpeechUtterance(
    private val utteranceId: String,
    private val dispatch: (() -> Unit) -> Unit,
    private val current: () -> Boolean,
    private val onStarted: () -> Unit,
    private val onDone: (Boolean) -> Unit,
    private val release: () -> Unit,
) : UtteranceProgressListener() {
    private var started = false
    private var finished = false

    override fun onStart(utteranceId: String?) {
        if (utteranceId != this.utteranceId) return
        dispatch {
            if (current() && !finished && !started) {
                started = true
                onStarted()
            }
        }
    }

    override fun onDone(utteranceId: String?) {
        finish(utteranceId, true)
    }

    @Deprecated("Deprecated in Java")
    override fun onError(utteranceId: String?) {
        finish(utteranceId, false)
    }

    override fun onError(
        utteranceId: String?,
        errorCode: Int,
    ) {
        finish(utteranceId, false)
    }

    override fun onStop(
        utteranceId: String?,
        interrupted: Boolean,
    ) {
        finish(utteranceId, false)
    }

    private fun finish(
        utteranceId: String?,
        success: Boolean,
    ) {
        if (utteranceId != this.utteranceId) return
        dispatch {
            if (current() && !finished) {
                finished = true
                release()
                onDone(success)
            }
        }
    }
}
