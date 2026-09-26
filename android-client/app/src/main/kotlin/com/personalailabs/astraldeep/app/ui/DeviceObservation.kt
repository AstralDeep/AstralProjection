// Measures the native content viewport and forwards current runtime capabilities to the authenticated client.
// Geometry and hardware changes update ROTE without replacing the conversation or its connection.

package com.personalailabs.astraldeep.app.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntSize
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.personalailabs.astraldeep.app.transport.RuntimeDeviceMonitor
import com.personalailabs.astraldeep.app.transport.deviceCapabilities
import com.personalailabs.astraldeep.app.transport.voiceDeviceId
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first

@Composable
internal fun DeviceObservation(
    vm: AppViewModel,
    token: String,
    supportedTypes: List<String>,
    content: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val density = LocalDensity.current
    val owner = LocalLifecycleOwner.current
    val monitor = remember(context) { RuntimeDeviceMonitor(context) }
    val deviceId = remember(context) { voiceDeviceId(context) }
    val facts by monitor.facts.collectAsStateWithLifecycle()
    var viewport by remember { mutableStateOf(IntSize.Zero) }
    val observed =
        if (viewport.width > 0 && viewport.height > 0) {
            deviceCapabilities(
                viewport.width, viewport.height, density.density.toDouble(), supportedTypes, deviceId, facts.voice,
                facts.hasTouch, facts.pointerType, facts.connectionType, facts.reducedMotion, consoleContract = "console/v2",
            )
        } else {
            null
        }
    val current by rememberUpdatedState(observed)
    DisposableEffect(monitor, owner) {
        monitor.start()
        val observer =
            LifecycleEventObserver { _, event ->
                if (event == Lifecycle.Event.ON_RESUME) monitor.refresh()
                if (event == Lifecycle.Event.ON_START) vm.appForegroundChanged(true)
                if (event == Lifecycle.Event.ON_STOP) vm.appForegroundChanged(false)
            }
        owner.lifecycle.addObserver(observer)
        vm.appForegroundChanged(owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
        onDispose {
            vm.appForegroundChanged(false)
            owner.lifecycle.removeObserver(observer)
            monitor.close()
        }
    }
    LaunchedEffect(token) {
        val device = snapshotFlow { current }.filterNotNull().first()
        vm.start(token, device)
    }
    LaunchedEffect(observed) { observed?.let(vm::updateDeviceCapabilities) }
    Box(Modifier.fillMaxSize().onSizeChanged { viewport = it }) { content() }
}
