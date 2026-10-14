// Observes Android audio-focus and audio-device changes while a voice session is active and forwards mapped
// interruption events to the app view model; VoiceSessionController owns the suspension and recovery policy.

package com.personalailabs.astraldeep.app.voice

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper

class VoiceAudioEnvironmentObserver(
    context: Context,
    private val onAudioFocusChanged: (interrupted: Boolean) -> Unit,
    private val onOutputRouteLost: () -> Unit,
) : AutoCloseable {
    private val audioManager = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    private val handler = Handler(Looper.getMainLooper())
    private var focusRequest: AudioFocusRequest? = null
    private var started = false
    private var closed = false

    private val focusListener =
        AudioManager.OnAudioFocusChangeListener { change ->
            voiceAudioFocusInterrupted(change)?.let(onAudioFocusChanged)
        }
    private val deviceListener =
        object : AudioDeviceCallback() {
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                if (removedDevices.any { device -> device.isSink || device.isSource }) onOutputRouteLost()
            }
        }

    fun start() {
        if (started || closed) return
        started = true
        audioManager?.registerAudioDeviceCallback(deviceListener, handler)
        requestFocus()
    }

    fun stop() {
        if (!started || closed) return
        started = false
        abandonFocus()
        audioManager?.unregisterAudioDeviceCallback(deviceListener)
    }

    private fun requestFocus() {
        val manager = audioManager ?: return
        val request =
            AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANT)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                ).setOnAudioFocusChangeListener(focusListener, handler)
                .build()
        focusRequest = request
        onAudioFocusChanged(voiceAudioFocusRequestInterrupted(manager.requestAudioFocus(request)))
    }

    private fun abandonFocus() {
        val request = focusRequest ?: return
        focusRequest = null
        audioManager?.abandonAudioFocusRequest(request)
    }

    override fun close() {
        if (closed) return
        closed = true
        stop()
    }
}
