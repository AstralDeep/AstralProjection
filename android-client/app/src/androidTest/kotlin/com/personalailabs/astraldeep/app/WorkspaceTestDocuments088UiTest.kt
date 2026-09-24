// Instrumented test for cross-UID document-provider access on API 34, where Shell cannot grant
// MANAGE_DOCUMENTS directly.

package com.personalailabs.astraldeep.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.security.NetworkSecurityPolicy
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.workspace.TestDocuments
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class WorkspaceTestDocuments088UiTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Before fun reset() = TestDocuments.reset()

    @After fun cleanup() = TestDocuments.reset()

    @Test fun syntheticLoopbackTransportWorksWithoutOpeningCoverageCleartextToOtherHosts() {
        val policy = NetworkSecurityPolicy.getInstance()
        assertTrue(policy.isCleartextTrafficPermitted("localhost"))
        assertTrue(policy.isCleartextTrafficPermitted("127.0.0.1"))
        if (BuildConfig.BUILD_TYPE == "coverage") {
            assertFalse(policy.isCleartextTrafficPermitted())
            assertFalse(policy.isCleartextTrafficPermitted("example.com"))
            assertFalse(policy.isCleartextTrafficPermitted("192.168.1.1"))
            assertFalse(policy.isCleartextTrafficPermitted("sub.localhost"))
        } else {
            assertEquals("debug", BuildConfig.BUILD_TYPE)
        }
    }

    @Test fun selectedDocumentGrantAllowsIoWithoutRootOrControlAuthorityAndCleanupRevokesIt() {
        assertEquals(PackageManager.PERMISSION_DENIED, context.checkSelfPermission(Manifest.permission.MANAGE_DOCUMENTS))
        val uri = TestDocuments.create("selected")
        context.contentResolver.openOutputStream(uri)!!.use { it.write("synthetic selected document".toByteArray()) }
        assertEquals("synthetic selected document", context.contentResolver.openInputStream(uri)!!.bufferedReader().use { it.readText() })
        assertTrue(TestDocuments.status(uri).getBoolean("opened"))
        assertTrue(
            runCatching {
                DocumentsContract.createDocument(context.contentResolver, DocumentsContract.buildDocumentUri(uri.authority!!, "root"), "text/html", "unselected")
            }.exceptionOrNull() is SecurityException,
        )
        assertTrue(runCatching { context.contentResolver.call(uri.authority!!, "test-reset", null, null) }.exceptionOrNull() is SecurityException)
        assertTrue(TestDocuments.status(uri).getBoolean("exists"))
        TestDocuments.reset()
        assertTrue(runCatching { context.contentResolver.openInputStream(uri)?.close() }.exceptionOrNull() is SecurityException)
    }

    @Test
    @SdkSuppress(minSdkVersion = 34)
    fun unrelatedShellCallerCannotResetTargetFixtureDocuments() {
        val uri = TestDocuments.create("preserved")
        val command = "content call --uri content://${TestDocuments.AUTHORITY} --method test-reset"
        val descriptors = instrumentation.uiAutomation.executeShellCommandRwe(command)
        val result =
            try {
                descriptors[1].close()
                ParcelFileDescriptor.AutoCloseInputStream(descriptors[2]).bufferedReader().use { it.readText() }
            } finally {
                descriptors.forEach { it.close() }
            }
        assertTrue(result.contains("SecurityException: Synthetic document control caller refused"))
        assertTrue(TestDocuments.status(uri).getBoolean("exists"))
        context.contentResolver.openOutputStream(uri)!!.use { it.write("still permitted".toByteArray()) }
        assertEquals("still permitted", context.contentResolver.openInputStream(uri)!!.bufferedReader().use { it.readText() })
    }
}
