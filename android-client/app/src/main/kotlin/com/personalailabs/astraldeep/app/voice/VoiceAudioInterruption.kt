// Pure mapping of Android audio-focus transitions to voice-session interruption state; consumed by
// VoiceAudioEnvironmentObserver and unit-tested on the JVM without a device.

package com.personalailabs.astraldeep.app.voice

import android.media.AudioManager

internal fun voiceAudioFocusInterrupted(focusChange: Int): Boolean? =
    when (focusChange) {
        AudioManager.AUDIOFOCUS_GAIN -> false
        AudioManager.AUDIOFOCUS_LOSS -> true
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> true
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> true
        else -> null
    }

internal fun voiceAudioFocusRequestInterrupted(focusResult: Int): Boolean = focusResult != AudioManager.AUDIOFOCUS_REQUEST_GRANTED
