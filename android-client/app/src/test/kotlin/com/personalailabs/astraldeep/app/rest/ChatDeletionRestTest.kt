// Verifies authenticated conversation deletion and failure refusal through the real REST client.
// A synthetic loopback server checks exact method, path encoding and credential placement.

package com.personalailabs.astraldeep.app.rest

import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class ChatDeletionRestTest {
    @Test fun deletionUsesAuthenticatedEncodedPathAndOnlyAcceptsSuccess() =
        runTest {
            MockWebServer().use { server ->
                server.start()
                val rest = AstralRest(server.url("/").toString())
                for (status in listOf(204, 200, 403, 404, 500)) {
                    server.enqueue(MockResponse().setResponseCode(status))
                    assertEquals(status in 200..299, rest.deleteChat("synthetic", "chat/id"))
                    val request = server.takeRequest()
                    assertEquals("DELETE", request.method)
                    assertEquals("/api/chats/chat%2Fid", request.path)
                    assertEquals("Bearer synthetic", request.getHeader("Authorization"))
                    assertEquals(0, request.body.size)
                }
            }
        }

    @Test fun unavailableServerRefusesDeletion() =
        runTest {
            val server = MockWebServer()
            server.start()
            val url = server.url("/").toString()
            server.shutdown()
            assertFalse(AstralRest(url).deleteChat("synthetic", "chat"))
        }
}
