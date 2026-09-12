package com.personalailabs.astraldeep.app

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.OutputStream

internal interface WorkspaceExportDestination {
    fun isEmpty(): Boolean

    fun open(): OutputStream

    fun delete()
}

/** One exact CreateDocument result; ownership begins only after opening its empty destination. */
internal class WorkspaceExportSave(private val destination: WorkspaceExportDestination) {
    private var opened = false

    suspend fun copy(
        source: File,
        isCurrent: () -> Boolean,
    ) = withContext(Dispatchers.IO) {
        ensureActive()
        check(isCurrent())
        check(destination.isEmpty())
        check(isCurrent())
        destination.open().use { output ->
            opened = true
            source.inputStream().use { input ->
                val buffer = ByteArray(8192)
                while (true) {
                    ensureActive()
                    check(isCurrent())
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                }
            }
        }
        ensureActive()
        check(isCurrent())
    }

    suspend fun cleanup() =
        withContext(NonCancellable + Dispatchers.IO) {
            // Unknown/nonempty callbacks are never ours to delete. A partial copy is.
            if (opened || destination.isEmpty()) destination.delete()
        }
}
