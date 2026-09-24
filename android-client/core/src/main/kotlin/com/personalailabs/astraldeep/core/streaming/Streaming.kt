// Translates the orchestrator's push-streaming protocol frames into Canvas ops, porting the verified Windows
// streaming.py; nodeKey bridges a stream to its workspace component_id when present, else a synthetic node.

package com.personalailabs.astraldeep.core.streaming

import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.protocol.StreamError
import com.personalailabs.astraldeep.core.sdui.CanvasOp
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

const val STREAM_NODE_PREFIX = "stream-"

fun streamNodeId(streamId: String): String = "$STREAM_NODE_PREFIX$streamId"

private fun nodeKey(
    streamId: String?,
    toolName: String?,
    componentId: String? = null,
): Pair<String, String>? =
    when {
        streamId != null -> (componentId ?: streamNodeId(streamId)) to streamId
        toolName != null -> "${STREAM_NODE_PREFIX}tool-$toolName" to "tool:$toolName"
        else -> null
    }

private fun errorComponent(
    node: String,
    err: StreamError,
): Component {
    val retryable = err.retryable
    val text = err.message ?: err.code ?: "stream error"
    val attrs =
        buildJsonObject {
            put("type", "alert")
            put("variant", if (retryable) "warning" else "error")
            put("title", if (retryable) "Live update interrupted" else "Live update failed")
            put("message", text)
        }
    return Component(type = "alert", id = node, attributes = attrs, children = emptyList())
}

private fun containerOf(
    node: String,
    comps: List<Component>,
): Component =
    Component(
        type = "container",
        id = node,
        attributes = buildJsonObject { put("type", "container") },
        children = comps,
    )

fun streamFrameToOps(
    frame: Inbound.UiStreamData,
    activeChat: String?,
    seqState: MutableMap<String, Int>,
): List<CanvasOp> {
    val (node, key) = nodeKey(frame.streamId, frame.toolName, frame.componentId) ?: return emptyList()

    val session = frame.sessionId
    if (session != null && activeChat != null && session != activeChat) return emptyList()

    val seq = frame.seq
    if (seq != null) {
        val last = seqState[key]
        if (last != null && seq <= last) return emptyList()
        seqState[key] = seq
    }
    if (frame.terminal) seqState.remove(key)

    frame.error?.let { return listOf(CanvasOp("upsert", node, errorComponent(node, it))) }

    val comps = frame.components
    if (comps.isEmpty()) return emptyList()
    val body = if (comps.size == 1) comps[0].copy(id = node) else containerOf(node, comps)
    return listOf(CanvasOp("upsert", node, body))
}

// Guards late joiners: must not blank content already retained by id
fun subscribeAckOps(
    msg: Inbound.StreamSubscribed,
    existingIds: Set<String> = emptySet(),
): List<CanvasOp> {
    val (node, _) = nodeKey(msg.streamId, msg.toolName, msg.componentId) ?: return emptyList()
    if (node in existingIds) return emptyList()
    val tool = msg.toolName ?: "tool"
    val attrs =
        buildJsonObject {
            put("type", "text")
            put("content", "Streaming $tool…")
        }
    return listOf(CanvasOp("upsert", node, Component("text", node, attrs, emptyList())))
}

fun streamErrorOps(msg: Inbound.StreamErrorMsg): List<CanvasOp> {
    val (node, _) = nodeKey(msg.streamId, msg.toolName) ?: return emptyList()
    val text = msg.error.message ?: msg.error.code ?: "stream error"
    val attrs =
        buildJsonObject {
            put("type", "alert")
            put("variant", "error")
            put("title", "Stream error")
            put("message", text)
        }
    return listOf(CanvasOp("upsert", node, Component("alert", node, attrs, emptyList())))
}
