// Controls only the test APK's own synthetic documents for SAF fixtures; target app I/O still uses ordinary
// per-URI grants. Backs WorkspaceTestDocuments.java and its controllers.

package com.personalailabs.astraldeep.app.workspace

import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import androidx.test.platform.app.InstrumentationRegistry

internal object TestDocuments {
    const val AUTHORITY = "com.personalailabs.astraldeep.test.workspace.documents.control"

    private fun call(
        method: String,
        arg: String? = null,
    ): Bundle =
        checkNotNull(InstrumentationRegistry.getInstrumentation().targetContext.contentResolver.call(AUTHORITY, method, arg, null))

    fun reset() {
        call("test-reset")
    }

    fun create(name: String): Uri = Uri.parse(checkNotNull(call("test-create", name).getString("uri")))

    fun status(uri: Uri): Bundle = call("test-status", DocumentsContract.getDocumentId(uri))

    fun release(uri: Uri) {
        call("test-release", DocumentsContract.getDocumentId(uri))
    }
}
