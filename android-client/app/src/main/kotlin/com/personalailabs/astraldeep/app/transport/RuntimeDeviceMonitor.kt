// Observes Android input, audio, connectivity and accessibility facts for ROTE capability aggregation.
// The activity refreshes permission facts on resume and releases all listeners when its host is disposed.

package com.personalailabs.astraldeep.app.transport

import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.hardware.input.InputManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.InputDevice
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class RuntimeDeviceFacts(
    val hasTouch: Boolean,
    val finePointer: Boolean,
    val connectionType: String,
    val reducedMotion: Boolean,
    val voice: RuntimeVoiceCapability,
) {
    val pointerType: String get() =
        if (finePointer) {
            "fine"
        } else if (hasTouch) {
            "coarse"
        } else {
            "none"
        }
}

class RuntimeDeviceMonitor(context: Context) : AutoCloseable {
    private val context = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private val input = context.getSystemService(Context.INPUT_SERVICE) as? InputManager
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    private val network = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
    private var started = false
    private var closed = false
    private val _facts = MutableStateFlow(readFacts())
    val facts: StateFlow<RuntimeDeviceFacts> = _facts.asStateFlow()

    private val inputListener =
        object : InputManager.InputDeviceListener {
            override fun onInputDeviceAdded(deviceId: Int) = refresh()

            override fun onInputDeviceRemoved(deviceId: Int) = refresh()

            override fun onInputDeviceChanged(deviceId: Int) = refresh()
        }
    private val audioListener =
        object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = refresh()

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = refresh()
        }
    private val networkListener =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = refresh()

            override fun onLost(network: Network) = refresh()

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) = refresh()
        }
    private val motionListener =
        object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean) = refresh()
        }

    fun start() {
        if (started || closed) return
        started = true
        input?.registerInputDeviceListener(inputListener, handler)
        audio?.registerAudioDeviceCallback(audioListener, handler)
        network?.registerDefaultNetworkCallback(networkListener, handler)
        context.contentResolver.registerContentObserver(
            Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE),
            false,
            motionListener,
        )
        refresh()
    }

    fun refresh() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { refresh() }
        } else if (!closed) {
            _facts.value = readFacts()
        }
    }

    private fun readFacts(): RuntimeDeviceFacts {
        val capabilities = network?.activeNetwork?.let { network.getNetworkCapabilities(it) }
        return RuntimeDeviceFacts(
            hasTouch = context.packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN),
            finePointer =
                (input?.inputDeviceIds ?: intArrayOf()).any { id ->
                    input?.getInputDevice(id)?.let {
                        it.supportsSource(InputDevice.SOURCE_MOUSE) || it.supportsSource(InputDevice.SOURCE_STYLUS)
                    } == true
                },
            connectionType =
                when {
                    capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true -> "ethernet"
                    capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true -> "wifi"
                    capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true -> "cellular"
                    else -> "unknown"
                },
            reducedMotion = Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f,
            voice = runtimeVoiceCapability(context),
        )
    }

    override fun close() {
        if (closed) return
        closed = true
        if (started) {
            input?.unregisterInputDeviceListener(inputListener)
            audio?.unregisterAudioDeviceCallback(audioListener)
            network?.unregisterNetworkCallback(networkListener)
            context.contentResolver.unregisterContentObserver(motionListener)
        }
        handler.removeCallbacksAndMessages(null)
    }
}
