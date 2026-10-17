// Observes Android audio-focus and device changes while voice is active and forwards lifecycle-fenced
// events to the view model; VoiceSessionController owns suspension and recovery policy.

package com.personalailabs.astraldeep.app.voice

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper

internal interface VoiceAudioEnvironment {
    fun start(
        onAudioFocusChanged: (Boolean) -> Unit,
        onOutputRouteLost: () -> Unit,
    )

    fun stop()
}

internal class VoiceAudioEnvironmentObserver(
    private val environment: VoiceAudioEnvironment,
    private val onAudioFocusChanged: (Boolean) -> Unit,
    private val onOutputRouteLost: () -> Unit,
) : AutoCloseable {
    constructor(
        context: Context,
        onAudioFocusChanged: (Boolean) -> Unit,
        onOutputRouteLost: () -> Unit,
    ) : this(AndroidVoiceAudioEnvironment(context), onAudioFocusChanged, onOutputRouteLost)

    private var started = false
    private var closed = false
    private var registration: Any? = null

    fun start() {
        if (started || closed) return
        started = true
        val current = Any()
        registration = current
        environment.start(
            { interrupted -> if (registration === current && !closed) onAudioFocusChanged(interrupted) },
            { if (registration === current && !closed) onOutputRouteLost() },
        )
    }

    fun stop() {
        if (!started || closed) return
        started = false
        registration = null
        environment.stop()
    }

    override fun close() {
        if (closed) return
        stop()
        closed = true
    }
}

private class AndroidVoiceAudioEnvironment(
    context: Context,
) : VoiceAudioEnvironment {
    private val audioManager = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    private val handler = Handler(Looper.getMainLooper())
    private var focusRequest: AudioFocusRequest? = null
    private var deviceListener: AudioDeviceCallback? = null

    override fun start(
        onAudioFocusChanged: (Boolean) -> Unit,
        onOutputRouteLost: () -> Unit,
    ) {
        val manager = audioManager ?: return
        val listener =
            object : AudioDeviceCallback() {
                override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                    if (removedDevices.any { device -> device.isSink || device.isSource }) onOutputRouteLost()
                }
            }
        deviceListener = listener
        manager.registerAudioDeviceCallback(listener, handler)
        val request =
            AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANT)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                ).setOnAudioFocusChangeListener(
                    { change -> voiceAudioFocusInterrupted(change)?.let(onAudioFocusChanged) },
                    handler,
                ).build()
        focusRequest = request
        onAudioFocusChanged(voiceAudioFocusRequestInterrupted(manager.requestAudioFocus(request)))
    }

    override fun stop() {
        val request = focusRequest
        focusRequest = null
        if (request != null) audioManager?.abandonAudioFocusRequest(request)
        val listener = deviceListener
        deviceListener = null
        if (listener != null) audioManager?.unregisterAudioDeviceCallback(listener)
    }
}
