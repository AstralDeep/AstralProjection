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
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import com.personalailabs.astraldeep.app.auth.ConversationResumeStore
import com.personalailabs.astraldeep.app.render.renderers.exportFilename
import com.personalailabs.astraldeep.app.rest.WorkspaceRequestException
import com.personalailabs.astraldeep.app.rest.WorkspaceRest
import com.personalailabs.astraldeep.app.transport.LocalSubmission
import com.personalailabs.astraldeep.app.ui.AppViewModel
import com.personalailabs.astraldeep.app.ui.ComponentActionContext
import com.personalailabs.astraldeep.app.ui.ComponentActionHandler
import com.personalailabs.astraldeep.app.ui.ComponentActionLeases
import com.personalailabs.astraldeep.core.chrome.ComponentChrome
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.File

/** Per-component decisions retain their exact session/component context, never credentials in UI state. */
internal class ComponentActionController(
    private val activity: ComponentActivity,
    private val currentToken: () -> String?,
    private val rest: WorkspaceRest = WorkspaceRest(AppConfig.API_BASE, allowLocalHttp = BuildConfig.DEBUG),
    resultRegistry: ActivityResultRegistry = activity.activityResultRegistry,
) {
    internal class ShareLink internal constructor(val url: String)

    private class Active(val ticket: ComponentActionLeases.Ticket, val vm: AppViewModel) {
        var job: Job? = null
        var file: File? = null
        var link: ShareLink? = null
    }

    private val leases = ComponentActionLeases()
    private val active = mutableListOf<Active>()
    private val mutablePending = MutableStateFlow<Set<Pair<String, String>>>(emptySet())
    val pending = mutablePending.asStateFlow()
    private val mutableShare = MutableStateFlow<ShareLink?>(null)
    val share = mutableShare.asStateFlow()
    private var pendingSave: Active? = null
    private var pickerOutstanding = false
    private val directory = File(activity.cacheDir, "component-exports")
    private val save =
        activity.registerForActivityResult(ActivityResultContracts.CreateDocument("text/csv"), resultRegistry) { uri ->
            val owned = pickerOutstanding
            pickerOutstanding = false
            val action = pendingSave
            pendingSave = null
            action?.job?.cancel()
            if (action == null || uri == null || !isCurrent(action)) {
                if (owned && uri != null) activity.lifecycleScope.launch { WorkspaceExportSave(destination(uri)).cleanup() }
                if (action != null) finish(action)
            } else {
                action.job?.cancel()
                action.job =
                    activity.lifecycleScope.launch {
                        val output = WorkspaceExportSave(destination(uri))
                        var saved = false
                        try {
                            check(owned)
                            output.copy(checkNotNull(action.file)) { isCurrent(action) }
                            if (isCurrent(action)) {
                                saved = true
                                notice("File saved")
                            }
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (_: Exception) {
                            if (isCurrent(action)) notice("Export could not be saved. Try again.")
                        } finally {
                            if (owned && !saved) output.cleanup()
                            finish(action)
                        }
                    }
            }
        }

    init {
        activity.lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onDestroy(owner: LifecycleOwner) {
                    clear()
                }
            },
        )
        directory.mkdirs()
        directory.listFiles()?.forEach { it.delete() }
    }

    fun handler(vm: AppViewModel): ComponentActionHandler =
        object : ComponentActionHandler {
            override val pending = this@ComponentActionController.pending

            override fun context(component: Component): ComponentActionContext? {
                val owner = ConversationResumeStore.accountFromAccessToken(currentToken().orEmpty()) ?: return null
                return vm.componentContext(component)?.takeIf { it.owner == owner }
            }

            override fun perform(
                context: ComponentActionContext,
                kind: String,
                payload: JsonObject,
            ) {
                if (context != this.context(context.component) || context.actions.none { it.kind == kind }) return
                when (kind) {
                    "refine" -> {
                        val instruction = (payload["instruction"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.trim()
                        if (instruction.isNullOrEmpty()) return
                        decide(
                            context,
                            kind,
                            vm,
                            "component_refine",
                            buildJsonObject {
                                put("component_id", context.componentId)
                                put("chat_id", context.chatId)
                                put("instruction", instruction)
                            },
                        )
                    }
                    "history" -> {
                        val version = (payload["version_no"] as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull ?: return
                        if (ComponentChrome.versions(context.component).none { it.versionNo == version }) return
                        decide(
                            context,
                            kind,
                            vm,
                            "component_restore",
                            buildJsonObject {
                                put("component_id", context.componentId)
                                put("chat_id", context.chatId)
                                put("version_no", version)
                            },
                        )
                    }
                    "csv", "share" -> request(context, kind, vm)
                }
            }
        }

    private fun decide(
        context: ComponentActionContext,
        kind: String,
        vm: AppViewModel,
        event: String,
        payload: JsonObject,
    ) {
        val ticket = leases.begin(context, kind) ?: return
        val action = Active(ticket, vm)
        active.add(action)
        updatePending()
        var submission: LocalSubmission? = null
        val sent = vm.sendComponentEvent(context, event, payload) { submission = it }
        val issued = submission
        if (!sent || issued == null) {
            finish(action)
            return
        }
        action.job =
            activity.lifecycleScope.launch {
                try {
                    // Normal reducers retain this exact submission through accepted/running,
                    // and remove it only on terminal/refusal or conversation retirement.
                    vm.state.first { state ->
                        !isCurrent(action) || state.pendingSubmissions[issued.requestGeneration] != issued
                    }
                } finally {
                    finish(action)
                }
            }
    }

    private fun request(
        context: ComponentActionContext,
        kind: String,
        vm: AppViewModel,
    ) {
        // One owned picker/link sheet per operation; a second component must not mint a hidden result.
        if (active.any { it.ticket.kind == kind }) return
        if (kind == "csv" && pickerOutstanding) return
        if (kind == "share" && mutableShare.value != null) return
        val ticket = leases.begin(context, kind) ?: return
        val action = Active(ticket, vm)
        active.add(action)
        updatePending()
        val token = currentToken().orEmpty()
        action.job =
            activity.lifecycleScope.launch {
                var retained = false
                try {
                    check(isCurrent(action))
                    if (kind == "share") {
                        val url = rest.shareComponent(token, context.chatId, context.componentId)
                        ensureActive()
                        if (isCurrent(action) && mutableShare.value == null) {
                            action.link = ShareLink(url).also { mutableShare.value = it }
                            retained = true
                        }
                    } else {
                        val file = File.createTempFile("component-", ".csv", directory)
                        action.file = file
                        rest.exportComponent(token, context.chatId, context.componentId, file)
                        ensureActive()
                        if (isCurrent(action) && !pickerOutstanding) {
                            pendingSave = action
                            save.launch(exportFilename(context.componentId, "csv"))
                            pickerOutstanding = true
                            retained = true
                        }
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: WorkspaceRequestException) {
                    if (isCurrent(action)) notice(failure.userMessage)
                } catch (_: Exception) {
                    if (isCurrent(action)) notice(if (kind == "share") "Couldn't create the share link." else "Couldn't export this table.")
                } finally {
                    if (!retained) finish(action)
                }
                if (retained) {
                    // Forgotten sheets/pickers retain no private bytes indefinitely.
                    action.job =
                        activity.lifecycleScope.launch {
                            delay(120_000)
                            finish(action)
                        }
                }
            }
    }

    fun copy(link: ShareLink) {
        val action = active.singleOrNull { it.link === link } ?: return
        if (!isCurrent(action)) {
            finish(action)
            return
        }
        val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        if (clipboard == null) {
            notice("Copy unavailable. Select and copy the link from this dialog.")
            return
        }
        clipboard.setPrimaryClip(ClipData.newPlainText("AstralDeep share link", link.url))
        notice("Share link copied to clipboard.")
    }

    fun dismiss(link: ShareLink) {
        active.singleOrNull { it.link === link }?.let {
            it.job?.cancel()
            finish(it)
        }
    }

    fun invalidateStale() {
        active.toList().filterNot(::isCurrent).forEach {
            it.job?.cancel()
            finish(it)
        }
    }

    fun clear() {
        active.toList().forEach {
            it.job?.cancel()
            finish(it)
        }
    }

    private fun isCurrent(action: Active): Boolean =
        leases.isCurrent(action.ticket, handler(action.vm).context(action.ticket.context.component))

    private fun finish(action: Active) {
        leases.finish(action.ticket)
        active.remove(action)
        updatePending()
        if (pendingSave === action) pendingSave = null
        if (action.link != null && mutableShare.value === action.link) mutableShare.value = null
        action.file?.delete()
    }

    private fun updatePending() {
        mutablePending.value = active.map { it.ticket.context.componentId to it.ticket.kind }.toSet()
    }

    private fun destination(uri: Uri) =
        object : WorkspaceExportDestination {
            override fun isEmpty(): Boolean =
                runCatching {
                    if (uri.scheme != "content" || !DocumentsContract.isDocumentUri(activity, uri)) return@runCatching false
                    activity.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                        val column = cursor.getColumnIndex(OpenableColumns.SIZE)
                        cursor.count == 1 && cursor.moveToFirst() && column >= 0 && cursor.getType(column) == Cursor.FIELD_TYPE_INTEGER &&
                            cursor.getLong(column) == 0L
                    } == true
                }.getOrDefault(false)

            override fun open() = activity.contentResolver.openOutputStream(uri, "wt") ?: error("No destination")

            override fun delete() {
                runCatching { DocumentsContract.deleteDocument(activity.contentResolver, uri) }
            }
        }

    private fun notice(message: String) = Toast.makeText(activity, message, Toast.LENGTH_LONG).show()
}
