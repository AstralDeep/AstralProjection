package com.personalailabs.astraldeep.app.transport

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class DeviceCapsTest {
    @Test
    fun builds_android_capabilities() {
        val caps = deviceCapabilities(widthPx = 1080, heightPx = 2340, pixelRatio = 2.75, supportedTypes = listOf("text", "card"))
        assertEquals("android", caps.deviceType)
        assertEquals(1080, caps.screenWidth)
        assertEquals(2340, caps.screenHeight)
        assertEquals(393, caps.viewportWidth)
        assertEquals(851, caps.viewportHeight)
        assertEquals(2.75, caps.pixelRatio)
        assertEquals(true, caps.hasTouch)
        assertEquals(listOf("text", "card"), caps.supportedTypes)
    }

    @Test
    fun phone_and_tablet_viewports_use_logical_pixels() {
        for ((width, height, density, expected) in listOf(
            listOf(1440.0, 3120.0, 3.5, 411.0),
            listOf(2560.0, 1600.0, 2.0, 1280.0),
            listOf(480.0, 800.0, 1.0, 480.0),
        )) {
            val caps = deviceCapabilities(width.toInt(), height.toInt(), density, emptyList())
            assertEquals(expected.toInt(), caps.viewportWidth)
            assertEquals(width.toInt(), caps.screenWidth)
        }
    }

    @Test
    fun invalid_physical_metrics_are_not_reported_as_real_capabilities() {
        for (density in listOf(0.0, -1.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            assertFailsWith<IllegalArgumentException> { deviceCapabilities(1080, 2340, density, emptyList()) }
        }
        assertFailsWith<IllegalArgumentException> { deviceCapabilities(0, 2340, 2.0, emptyList()) }
        assertFailsWith<IllegalArgumentException> { deviceCapabilities(1080, -1, 2.0, emptyList()) }
    }

    @Test
    fun reportsExplicitVoiceCapturePlaybackAndPermissionFacts() {
        val caps =
            deviceCapabilities(
                widthPx = 1080,
                heightPx = 2340,
                pixelRatio = 2.75,
                supportedTypes = emptyList(),
                deviceId = "00000000-0000-4000-8000-000000000001",
                voice = RuntimeVoiceCapability(true, true, "authorized", true),
            )

        assertEquals("00000000-0000-4000-8000-000000000001", caps.deviceId)
        assertEquals(true, caps.hasMicrophone)
        assertEquals(true, caps.hasAudioOutput)
        assertEquals("authorized", caps.microphonePermission)
        assertEquals(true, caps.fullDuplex)
        assertEquals("livekit", caps.voiceTransport)
    }
}
