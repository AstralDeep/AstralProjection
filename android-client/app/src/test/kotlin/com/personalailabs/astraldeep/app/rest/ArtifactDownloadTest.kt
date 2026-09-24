// Tests for ArtifactDownload's bearer-token REST client against a loopback MockWebServer, including refusal
// of non-bearer public URLs.

package com.personalailabs.astraldeep.app.rest

import okhttp3.HttpUrl
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import java.io.ByteArrayOutputStream
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class ArtifactDownloadTest {
    @Test
    fun resolves_only_same_origin_https_export_and_download_endpoints() {
        val base = "https://astral.example"
        assertEquals("https://astral.example/api/export/canvas/chat.html", artifactDownloadUrl(base, "/api/export/canvas/chat.html").toString())
        assertEquals("https://astral.example/api/download/chat/file.txt", artifactDownloadUrl(base, "$base/api/download/chat/file.txt").toString())
        for (bad in listOf(
            "https://other.example/api/export/x", "//other.example/api/export/x", "http://astral.example/api/export/x",
            "https://astral.example:8443/api/export/x", "https://user@astral.example/api/export/x", "/api/export/x#fragment",
            "/api/export/../auth/logout", "/api/export/%2e%2e/auth/logout", "/api/export/%252e%252e/auth/logout",
            "/api/export/x%2fy", "/api/export/x%5cy", "/api/export/x%00", "/api/export/x\\y", "relative", "/api/auth/logout",
        )) assertFails(bad) { artifactDownloadUrl(base, bad) }
        assertFails { artifactDownloadUrl("http://astral.example", "/api/export/x", allowLocalHttp = true) }
    }

    @Test
    fun public_https_files_are_handed_to_browser_without_authentication_and_downgrade_is_denied() {
        val public = "https://github.com/organisation/project/releases/download/1.0/app.apk"
        assertEquals(public, publicDownloadBrowserUrl("https://astral.example", public).toString())
        assertNull(publicDownloadBrowserUrl("https://astral.example", "/api/export/canvas/a.html"))
        assertNull(publicDownloadBrowserUrl("http://10.0.2.2:8001", "http://10.0.2.2:8001/api/export/a.html"))
        assertNull(publicDownloadBrowserUrl("https://astral.example", "https://astral.example/api/export/a.html"))
        for (bad in listOf("http://github.com/app.apk", "https://user:token@github.com/app.apk", "https://github.com/app.apk#frag", "https://github.com/\\evil")) {
            assertFails { publicDownloadBrowserUrl("https://astral.example", bad) }
        }
        assertFails { ArtifactDownload("https://astral.example").copyTo(public, "", ByteArrayOutputStream()) }
        assertFails { ArtifactDownload("https://astral.example").copyTo(public, "private-token", ByteArrayOutputStream()) }
    }

    @Test
    fun filename_cannot_escape_native_destination() {
        assertEquals("safe.csv", safeDownloadFilename("safe.csv"))
        assertEquals("_private_secret.csv", safeDownloadFilename("../private/secret.csv"))
        assertEquals("download", safeDownloadFilename(".."))
        assertEquals(120, safeDownloadFilename("x".repeat(200)).length)
    }

    @Test
    fun authenticated_download_copies_bytes_and_never_follows_redirect() {
        MockWebServer().use { origin ->
            MockWebServer().use { external ->
                origin.enqueue(MockResponse().setBody("export bytes"))
                val downloader = ArtifactDownload(origin.localUrl("/").toString(), allowLocalHttp = true)
                val sink = ByteArrayOutputStream()
                downloader.copyTo("/api/export/canvas/a.html", "test-token", sink)
                assertEquals("export bytes", sink.toString())
                assertEquals("Bearer test-token", origin.takeRequest().getHeader("Authorization"))
                origin.enqueue(MockResponse().setResponseCode(302).setHeader("Location", external.localUrl("/capture")))
                assertFailsWith<IOException> { downloader.copyTo("/api/export/canvas/a.html", "test-token", ByteArrayOutputStream()) }
                assertEquals(0, external.requestCount)
                assertFails { downloader.copyTo(external.localUrl("/api/export/x").toString(), "test-token", ByteArrayOutputStream()) }
                assertEquals(0, external.requestCount)
            }
        }
    }

    @Test
    fun server_denials_and_bounded_stream_fail_honestly() {
        MockWebServer().use { server ->
            val downloader = ArtifactDownload(server.localUrl("/").toString(), allowLocalHttp = true, maxBytes = 4)
            server.enqueue(MockResponse().setResponseCode(403))
            assertFailsWith<IOException> { downloader.copyTo("/api/download/chat/file", "token", ByteArrayOutputStream()) }
            server.enqueue(MockResponse().setBody("too large"))
            assertFailsWith<IOException> { downloader.copyTo("/api/download/chat/file", "token", ByteArrayOutputStream()) }
            server.enqueue(MockResponse().setChunkedBody("too large", 2))
            assertFailsWith<IOException> { downloader.copyTo("/api/download/chat/file", "token", ByteArrayOutputStream()) }
            assertFails { downloader.copyTo("/api/download/chat/file", "", ByteArrayOutputStream()) }
            assertEquals(3, server.requestCount)
        }
    }
}

private fun MockWebServer.localUrl(path: String): HttpUrl = url(path).newBuilder().host("localhost").build()
