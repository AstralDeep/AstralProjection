// Wraps one SAF CreateDocument result; ownership begins only once opened, guarding against deleting a file
// this code didn't create. Used by WorkspaceActionController.

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
            // Never delete a destination we didn't open or fill ourselves
            if (opened || destination.isEmpty()) destination.delete()
        }
}
