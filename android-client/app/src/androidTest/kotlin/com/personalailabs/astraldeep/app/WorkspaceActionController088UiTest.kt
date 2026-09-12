package com.personalailabs.astraldeep.app

import android.Manifest
import android.content.Intent
import androidx.lifecycle.Lifecycle
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.ui.Screen
import com.personalailabs.astraldeep.app.workspace.DOCUMENT_AUTHORITY
import com.personalailabs.astraldeep.app.workspace.WorkspaceControllerFixture
import com.personalailabs.astraldeep.app.workspace.WorkspaceControllerFixture.Companion.await
import com.personalailabs.astraldeep.app.workspace.WorkspaceControllerFixture.Companion.main
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Synthetic controller integration; actual transport, WebView, ActivityResultRegistry and DocumentsProvider. */
class WorkspaceActionController088UiTest {
    @Before fun grantTestProviderAccess() {
        InstrumentationRegistry.getInstrumentation().uiAutomation.adoptShellPermissionIdentity(Manifest.permission.MANAGE_DOCUMENTS)
        InstrumentationRegistry.getInstrumentation().targetContext.contentResolver.call(DOCUMENT_AUTHORITY, "test-reset", null, null)
    }

    @After fun releaseTestProviderAccess() {
        InstrumentationRegistry.getInstrumentation().targetContext.contentResolver.call(DOCUMENT_AUTHORITY, "test-reset", null, null)
        InstrumentationRegistry.getInstrumentation().uiAutomation.dropShellPermissionIdentity()
    }

    @Test fun shareCopiesValidatedLinkAndDuplicateInflightMakesOnePost() =
        withFixture {
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            response = { request ->
                normalResponse(request).also {
                    entered.countDown()
                    check(release.await(10, TimeUnit.SECONDS))
                }
            }
            perform("share_canvas")
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            perform("share_canvas")
            assertEquals(1, requests.size)
            assertEquals("unchanged", clipboard())
            release.countDown()
            await { clipboard() != "unchanged" }
            assertEquals(server.url("/share/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").toString(), clipboard())
            assertEquals("POST", requests.single().method)
            assertEquals("""{"chat_id":"${WorkspaceControllerFixture.CHAT}","scope":"canvas"}""", requests.single().body.readUtf8())
            assertTrue(cacheFiles().isEmpty())
        }

    @Test fun lateShareAfterOwnerChangeCannotCopyAndNeverRetargetsNewTicket() =
        withFixture {
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            response = { request ->
                normalResponse(request).also {
                    entered.countDown()
                    check(release.await(10, TimeUnit.SECONDS))
                }
            }
            perform("share_canvas")
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            invalidate { token = WorkspaceControllerFixture.syntheticToken("other-owner") }
            release.countDown()
            awaitCallCompletion("/api/share")
            assertEquals("unchanged", clipboard())
            invalidate { token = WorkspaceControllerFixture.syntheticToken("owner") }
            response = { MockResponse().setResponseCode(201).setBody("""{"share_url":"/share/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}""") }
            perform("share_canvas")
            await { clipboard().endsWith("/share/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") }
            awaitCallCompletion("/api/share", 1)
            assertEquals(2, requests.size)
            assertEquals(server.url("/share/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb").toString(), clipboard())
            assertTrue(cacheFiles().isEmpty())
            assertTrue(registry.launches.isEmpty())
        }

    @Test fun uncertainSharePostIsNotRetriedAndLeavesClipboardUntouched() =
        withFixture {
            response = { MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST) }
            perform("share_canvas")
            await { requests.isNotEmpty() }
            Thread.sleep(400)
            assertEquals(1, requests.size)
            assertEquals("unchanged", clipboard())
            assertTrue(registry.launches.isEmpty())
        }

    @Test fun phiShareRefusalCannotCreateAClipboardLink() =
        withFixture {
            response = { MockResponse().setResponseCode(403).setBody("""{"error":"phi_blocked"}""") }
            perform("share_canvas")
            await { requests.isNotEmpty() }
            Thread.sleep(200)
            assertEquals("unchanged", clipboard())
            assertEquals(1, requests.size)
        }

    @Test fun exportUsesCurrentNativeCaptureAndSavesScriptFreeDocument() =
        withFixture {
            export()
            assertEquals(Intent.ACTION_CREATE_DOCUMENT, registry.launches.single().intent.action)
            assertEquals("text/html", registry.launches.single().intent.type)
            assertEquals("canvas.html", registry.launches.single().intent.getStringExtra(Intent.EXTRA_TITLE))
            val post = requests.single { it.method == "POST" }
            val capture = Json.parseToJsonElement(post.body.clone().readUtf8()).jsonObject
            assertEquals(setOf("version", "components", "viewport", "theme", "display_state", "images"), capture.keys)
            assertTrue(capture.toString().contains("Synthetic visible canvas"))
            assertFalse(capture.toString().contains(checkNotNull(token)))
            val uri = document("saved")
            complete(uri)
            await { status(uri).getLong("size") > 0 && cacheFiles().isEmpty() }
            val saved = resolver.openInputStream(uri)!!.bufferedReader().use { it.readText() }
            assertTrue(saved.contains("Synthetic visible canvas"))
            assertFalse(saved.contains("<script", ignoreCase = true))
            assertFalse(saved.contains("Authorization"))
            assertTrue(status(uri).getBoolean("opened"))
        }

    @Test fun pickerCancellationRemovesPreparedPrivateFileAndAllowsNextExport() =
        withFixture {
            export()
            assertEquals(1, cacheFiles().size)
            complete(null)
            await { cacheFiles().isEmpty() }
            perform("export_canvas")
            await { registry.launches.size == 2 }
            complete(null)
            await { cacheFiles().isEmpty() }
        }

    @Test fun stalePickerDeletesOnlyItsEmptyDocumentAndCannotLaunchOverlappingPicker() =
        withFixture {
            export()
            perform("export_canvas")
            assertEquals(1, registry.launches.size)
            val uri = document("empty")
            invalidate { model.newChat() }
            await { cacheFiles().isEmpty() }
            complete(uri)
            await { !status(uri).getBoolean("exists") }
            assertFalse(status(uri).getBoolean("opened"))
        }

    @Test fun staleNonemptyDocumentIsNeverTruncatedOrDeleted() =
        withFixture {
            export()
            val uri = document("preserved")
            resolver.openOutputStream(uri)!!.use { it.write("existing synthetic contents".toByteArray()) }
            invalidate { model.goTo(Screen.History) }
            await { cacheFiles().isEmpty() }
            complete(uri)
            Thread.sleep(200)
            assertTrue(status(uri).getBoolean("exists"))
            assertEquals("existing synthetic contents", resolver.openInputStream(uri)!!.bufferedReader().use { it.readText() })
        }

    @Test fun failedDestinationOpenRemovesOnlyEmptyOwnedDocument() =
        withFixture {
            export()
            val uri = document("refuse")
            complete(uri)
            await { !status(uri).getBoolean("exists") && cacheFiles().isEmpty() }
            assertTrue(status(uri).getBoolean("opened"))
        }

    @Test fun cancellationAfterPartialWriteCleansOwnedBytesAndPreservesNeighbor() =
        WorkspaceControllerFixture(canvasText = "Synthetic visible canvas ".repeat(12000)).use {
            with(it) {
                export()
                val neighbor = document("neighbor")
                resolver.openOutputStream(neighbor)!!.use { it.write("keep".toByteArray()) }
                val uri = document("paused")
                complete(uri)
                await { status(uri).getLong("size") > 0 }
                assertTrue("The pipe must still block the active copy before cancellation", cacheFiles().isNotEmpty())
                invalidate { token = null }
                release(uri)
                await { !status(uri).getBoolean("exists") && cacheFiles().isEmpty() }
                assertEquals("keep", resolver.openInputStream(neighbor)!!.bufferedReader().use { it.readText() })
            }
        }

    @Test fun revisionMismatchNeverPostsCaptureOrOpensPicker() =
        withFixture {
            response = { MockResponse().setHeader("X-Astral-Render-Revision", "2").setBody("wrong revision") }
            perform("export_canvas")
            await { requests.isNotEmpty() }
            Thread.sleep(200)
            assertEquals(listOf("GET"), requests.map { it.method })
            assertTrue(registry.launches.isEmpty())
            assertTrue(cacheFiles().isEmpty())
        }

    @Test fun activityDestructionDisposesPrivateExportWithoutSaving() =
        withFixture {
            export()
            val privateFile = cacheFiles().single()
            scenario.moveToState(Lifecycle.State.DESTROYED)
            await { !privateFile.exists() }
        }

    @Test fun postFreezeLocalLayoutChangeDoesNotInvalidateCurrentSave() =
        withFixture {
            export()
            main { capture.expand("/components/0", true) }
            val uri = document("frozen")
            complete(uri)
            await { status(uri).getLong("size") > 0 && cacheFiles().isEmpty() }
            assertTrue(resolver.openInputStream(uri)!!.bufferedReader().use { it.readText() }.contains("Synthetic visible canvas"))
        }

    @Test fun sameOwnerReconnectRetainsPendingShare() =
        withFixture {
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            response = { request ->
                normalResponse(request).also {
                    entered.countDown()
                    check(release.await(10, TimeUnit.SECONDS))
                }
            }
            perform("share_canvas")
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            reconnect()
            invalidate { }
            release.countDown()
            await { clipboard() != "unchanged" }
            assertEquals(server.url("/share/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").toString(), clipboard())
            assertEquals(1, requests.count { it.path == "/api/share" })
        }

    @Test fun capabilityRemovalDuringAuthorizationNeverCapturesOrPosts() =
        withFixture {
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            response = { request ->
                normalResponse(request).also {
                    entered.countDown()
                    check(release.await(10, TimeUnit.SECONDS))
                }
            }
            perform("export_canvas")
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            menu(false)
            invalidate { }
            release.countDown()
            awaitCallCompletion("/api/export/canvas/${WorkspaceControllerFixture.CHAT}.html")
            assertTrue(registry.launches.isEmpty())
            assertEquals(listOf("GET"), requests.map { it.method })
            assertTrue(cacheFiles().isEmpty())
            response = ::normalResponse
            menu(true)
            export()
            awaitCallCompletion("/api/export/canvas/${WorkspaceControllerFixture.CHAT}.html", 1)
            awaitCallCompletion("/api/export/canvas/${WorkspaceControllerFixture.CHAT}/presentation")
            assertEquals(listOf("GET", "GET", "POST"), requests.map { it.method })
            assertEquals(1, registry.launches.size)
            complete(null)
            await { cacheFiles().isEmpty() }
        }

    @Test fun committedRevisionChangeRetiresPreparedExportBeforeSave() =
        withFixture {
            export()
            val uri = document("oldrevision")
            commitRevision(2)
            invalidate { }
            await { cacheFiles().isEmpty() }
            complete(uri)
            await { !status(uri).getBoolean("exists") }
            assertFalse(status(uri).getBoolean("opened"))
        }

    @Test fun lifecycleDefersPickerCallbackAndRechecksOwnerWhenResumed() =
        withFixture {
            export()
            val uri = document("deferred")
            scenario.moveToState(Lifecycle.State.CREATED)
            complete(uri)
            assertEquals(1, cacheFiles().size)
            assertFalse(status(uri).getBoolean("opened"))
            invalidate { token = null }
            scenario.moveToState(Lifecycle.State.RESUMED)
            await { !status(uri).getBoolean("exists") && cacheFiles().isEmpty() }
            assertFalse(status(uri).getBoolean("opened"))
        }

    private fun withFixture(block: WorkspaceControllerFixture.() -> Unit) = WorkspaceControllerFixture().use(block)
}
