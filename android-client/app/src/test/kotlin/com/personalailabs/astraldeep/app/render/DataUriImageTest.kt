package com.personalailabs.astraldeep.app.render

import com.personalailabs.astraldeep.app.render.renderers.dataUriBytes
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertNull

/**
 * Feature 076 — the `image` primitive accepts the `data:image/…;base64,…` URLs
 * that carry screenshots of the user's own computer (the same form the web and
 * Windows renderers already accept). Pure JVM: only the decoder is exercised.
 */
class DataUriImageTest {
    @Test
    fun base64_image_data_url_decodes_to_its_bytes() {
        val bytes = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 0, 1, 2, 3)
        val url = "data:image/jpeg;base64," + Base64.getEncoder().encodeToString(bytes)
        assertContentEquals(bytes, dataUriBytes(url))
    }

    @Test
    fun other_sources_are_left_to_coil() {
        assertNull(dataUriBytes(null))
        assertNull(dataUriBytes("https://example.test/a.png"))
        assertNull(dataUriBytes("data:text/plain;base64,aGk="))
        assertNull(dataUriBytes("data:image/png,not-base64"))
        assertNull(dataUriBytes("data:image/png;base64,"))
        assertNull(dataUriBytes("data:image/png;base64,%%%not-base64%%%"))
    }
}
