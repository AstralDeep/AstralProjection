package com.personalailabs.astraldeep.app.rest

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull

class ComponentRest088Test {
    @Test fun component_share_uses_exact_scope_identity_and_existing_closed_response_policy() =
        runBlocking {
            MockWebServer().use { server ->
                val api = WorkspaceRest(server.url("/").toString(), allowLocalHttp = true)
                server.enqueue(MockResponse().setResponseCode(201).setBody("""{"share_url":"/share/${"a".repeat(32)}"}"""))
                assertEquals(server.url("/share/${"a".repeat(32)}").toString(), api.shareComponent("token", "chat", "wc_a"))
                val request = server.takeRequest()
                assertEquals("POST", request.method)
                assertEquals("/api/share", request.path)
                assertEquals("Bearer token", request.getHeader("Authorization"))
                assertEquals("no-store", request.getHeader("Cache-Control"))
                assertEquals("""{"chat_id":"chat","scope":"component","component_id":"wc_a"}""", request.body.readUtf8())
                server.enqueue(MockResponse().setResponseCode(403).setBody("""{"error":"phi_blocked","detail":"private"}"""))
                assertEquals("Sharing refused: the content matched the PHI gate.", assertFailsWith<WorkspaceRequestException> { api.shareComponent("token", "chat", "wc_a") }.userMessage)
                server.takeRequest()
                server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))
                assertFailsWith<WorkspaceRequestException> { api.shareComponent("token", "chat", "wc_a") }
                server.takeRequest()
                assertNull(server.takeRequest(200, TimeUnit.MILLISECONDS))
                assertFailsWith<WorkspaceRequestException> { api.shareComponent("token", "chat", "") }
                Unit
            }
        }

    @Test fun csv_is_authenticated_bounded_and_failed_or_cancelled_bytes_are_removed() =
        runBlocking {
            MockWebServer().use { server ->
                val api = WorkspaceRest(server.url("/").toString(), allowLocalHttp = true, maxExportBytes = 12)
                val file = Files.createTempFile("component-test", ".csv").toFile()
                try {
                    server.enqueue(MockResponse().setBody("a,b\n1,2"))
                    api.exportComponent("token", "chat", "wc_a", file)
                    assertEquals("a,b\n1,2", file.readText())
                    val request = server.takeRequest()
                    assertEquals("/api/export/component/wc_a.csv?chat_id=chat", request.path)
                    assertEquals("Bearer token", request.getHeader("Authorization"))
                    server.enqueue(MockResponse().setBody("x".repeat(13)))
                    assertFailsWith<WorkspaceRequestException> { api.exportComponent("token", "chat", "wc_a", file) }
                    assertFalse(file.exists())
                    server.takeRequest()
                    file.createNewFile()
                    server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
                    val job = async(start = CoroutineStart.UNDISPATCHED) { api.exportComponent("token", "chat", "wc_a", file) }
                    server.takeRequest()
                    job.cancelAndJoin()
                    assertFalse(file.exists())
                } finally {
                    file.delete()
                }
            }
        }
}
