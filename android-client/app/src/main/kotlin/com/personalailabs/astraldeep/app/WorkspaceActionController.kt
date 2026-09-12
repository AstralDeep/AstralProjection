package com.personalailabs.astraldeep.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.lifecycleScope
import com.personalailabs.astraldeep.app.auth.ConversationResumeStore
import com.personalailabs.astraldeep.app.render.CanvasCapture
import com.personalailabs.astraldeep.app.render.CanvasCaptureRegistry
import com.personalailabs.astraldeep.app.render.CanvasCaptureUnavailable
import com.personalailabs.astraldeep.app.render.renderOfflineCanvasExport
import com.personalailabs.astraldeep.app.rest.WorkspaceRequestException
import com.personalailabs.astraldeep.app.rest.WorkspaceRest
import com.personalailabs.astraldeep.app.ui.AppViewModel
import com.personalailabs.astraldeep.app.ui.WorkspaceActionLeases
import com.personalailabs.astraldeep.app.ui.WorkspaceContext
import com.personalailabs.astraldeep.app.ui.workspaceControls
import com.personalailabs.astraldeep.core.chrome.TopBarControl
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import java.io.File

/** Private prepared exports live only until this Activity's explicit save decision. */
internal class WorkspaceActionController(
    private val activity: ComponentActivity,
    private val currentToken: () -> String?,
    private val canvasCapture: CanvasCaptureRegistry,
) {
    private val leases = WorkspaceActionLeases()

    private class Active(val ticket: WorkspaceActionLeases.Ticket, val vm: AppViewModel) {
        var job: Job? = null
        var file: File? = null
        var capture: CanvasCapture? = null
    }

    private val active = mutableMapOf<String, Active>()
    private var pendingSave: Active? = null
    private var pickerOutstanding = false
    private val directory = File(activity.cacheDir, "workspace-exports")
    private val rest = WorkspaceRest(AppConfig.API_BASE, allowLocalHttp = BuildConfig.DEBUG)
    private val save =
        activity.registerForActivityResult(ActivityResultContracts.CreateDocument("text/html")) { uri ->
            val ownedLaunch = pickerOutstanding
            pickerOutstanding = false
            val action = pendingSave
            pendingSave = null
            if (action != null) {
                action.job?.cancel()
                if (uri == null || !isCurrent(action)) {
                    if (uri != null && ownedLaunch) discardDestination(uri)
                    finish(action)
                } else {
                    action.job =
                        activity.lifecycleScope.launch {
                            var saved = false
                            val destination = WorkspaceExportSave(documentDestination(uri))
                            try {
                                val source = checkNotNull(action.file)
                                check(ownedLaunch)
                                destination.copy(source) { isCurrent(action) }
                                if (isCurrent(action)) {
                                    saved = true
                                    notice("File saved")
                                }
                            } catch (cancelled: CancellationException) {
                                throw cancelled
                            } catch (_: Exception) {
                                if (isCurrent(action)) notice("Export could not be saved. Try again.")
                            } finally {
                                if (!saved && ownedLaunch) destination.cleanup()
                                finish(action)
                            }
                        }
                }
            } else if (uri != null && ownedLaunch) {
                discardDestination(uri)
            }
        }

    init {
        // This dedicated cache has no provider grants; recover files left by process death.
        directory.mkdirs()
        directory.listFiles()?.forEach { it.delete() }
    }

    fun perform(
        control: TopBarControl,
        vm: AppViewModel,
    ) {
        if (control !in workspaceControls(vm.state.value)) return
        if (control.operation == "export_canvas" && pickerOutstanding) return
        val context = currentContext(vm) ?: return
        val ticket = leases.begin(control.operation ?: return, context) ?: return
        val action = Active(ticket, vm)
        active[ticket.operation] = action
        val token = currentToken().orEmpty()
        action.job =
            activity.lifecycleScope.launch {
                var awaitingSave = false
                try {
                    check(isCurrent(action))
                    if (ticket.operation == "share_canvas") {
                        val url = rest.shareCanvas(token, context.chatId)
                        ensureActive()
                        if (isCurrent(action)) {
                            val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                            if (clipboard == null) {
                                notice("Share link: $url")
                            } else {
                                clipboard.setPrimaryClip(ClipData.newPlainText("AstralDeep share link", url))
                                notice("Share link copied to clipboard.")
                            }
                        }
                    } else {
                        rest.authorizeCanvas(token, context.chatId, context.revision)
                        if (!isCurrent(action)) throw CanvasCaptureUnavailable()
                        val capture = canvasCapture.freeze(context)
                        action.capture = capture
                        if (!isCurrent(action)) throw CanvasCaptureUnavailable()
                        val presentation = rest.canvasPresentation(token, context.chatId, context.revision, capture.presentation)
                        if (!isCurrent(action)) throw CanvasCaptureUnavailable()
                        val file = File.createTempFile("canvas-", ".html", directory)
                        action.file = file
                        renderOfflineCanvasExport(activity, presentation, file) { isCurrent(action) }
                        ensureActive()
                        if (isCurrent(action)) {
                            pendingSave = action
                            save.launch("canvas.html")
                            pickerOutstanding = true
                            awaitingSave = true
                        }
                    }
                } catch (_: TimeoutCancellationException) {
                    ensureActive()
                    if (isCurrent(action)) notice("Export timed out. Try again.")
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: CanvasCaptureUnavailable) {
                    if (isCurrent(action)) notice("Couldn’t capture this canvas for export. Reopen the result or use the web client.")
                } catch (failure: WorkspaceRequestException) {
                    if (isCurrent(action)) notice(failure.userMessage)
                } catch (_: Exception) {
                    if (isCurrent(action)) {
                        val message =
                            if (ticket.operation == "share_canvas") {
                                "Couldn't create the share link."
                            } else {
                                "Export failed. Try again."
                            }
                        notice(message)
                    }
                } finally {
                    if (!awaitingSave) finish(action)
                }
                if (awaitingSave) {
                    // A forgotten picker must not retain private HTML for an unbounded time.
                    action.job =
                        activity.lifecycleScope.launch {
                            delay(120_000)
                            if (pendingSave === action) {
                                pendingSave = null
                                finish(action)
                            }
                        }
                }
            }
    }

    fun invalidateStale() {
        active.values.toList().filterNot(::isCurrent).forEach {
            it.job?.cancel()
            finish(it)
        }
    }

    fun clear() {
        canvasCapture.clear()
        active.values.toList().forEach {
            it.job?.cancel()
            finish(it)
        }
    }

    private fun currentContext(vm: AppViewModel): WorkspaceContext? {
        val context = vm.workspaceContext() ?: return null
        val owner = ConversationResumeStore.accountFromAccessToken(currentToken().orEmpty())
        return context.takeIf { it.owner == owner }
    }

    private fun isCurrent(action: Active): Boolean =
        leases.isCurrent(action.ticket, currentContext(action.vm)) &&
            (action.capture == null || currentContext(action.vm)?.let { action.capture!!.canDeliver(it) } == true)

    private fun finish(action: Active) {
        leases.finish(action.ticket)
        if (active[action.ticket.operation] === action) active.remove(action.ticket.operation)
        if (pendingSave === action) pendingSave = null
        action.file?.delete()
    }

    private fun discardDestination(uri: Uri) {
        activity.lifecycleScope.launch { WorkspaceExportSave(documentDestination(uri)).cleanup() }
    }

    private fun documentDestination(uri: Uri) =
        object : WorkspaceExportDestination {
            override fun isEmpty(): Boolean =
                runCatching {
                    if (uri.scheme != "content" || !DocumentsContract.isDocumentUri(activity, uri)) return@runCatching false
                    activity.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                        val column = cursor.getColumnIndex(OpenableColumns.SIZE)
                        cursor.count == 1 && cursor.moveToFirst() && column >= 0 &&
                            cursor.getType(column) == Cursor.FIELD_TYPE_INTEGER && cursor.getLong(column) == 0L
                    } == true
                }.getOrDefault(false)

            override fun open() = activity.contentResolver.openOutputStream(uri, "wt") ?: error("No destination")

            override fun delete() {
                runCatching { DocumentsContract.deleteDocument(activity.contentResolver, uri) }
            }
        }

    private fun notice(message: String) = Toast.makeText(activity, message, Toast.LENGTH_LONG).show()
}
