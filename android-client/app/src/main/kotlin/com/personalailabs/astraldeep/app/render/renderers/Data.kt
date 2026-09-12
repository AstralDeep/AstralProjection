package com.personalailabs.astraldeep.app.render.renderers

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.ui.HistoryEmpty
import com.personalailabs.astraldeep.app.ui.HistoryHeader
import com.personalailabs.astraldeep.app.ui.HistoryRow
import com.personalailabs.astraldeep.core.protocol.ChatSummary
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/** Register the data primitives (US2): list, table, tabs, chat_history, skeleton. */
fun Renderer.registerDataRenderers(): Renderer =
    apply {
        register("list") { c -> ListPrimitive(c) { render(it) } }
        register("table") { c -> TablePrimitive(c, emit) }
        register("tabs") { c -> TabsPrimitive(c) { render(it) } }
        register("chat_history") { c -> ChatHistoryPrimitive(c, emit) }
        register("skeleton") { c -> SkeletonPrimitive(c) }
    }

@Composable
private fun ListPrimitive(
    c: Component,
    renderChild: @Composable (Component) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (c.children.isNotEmpty()) {
            c.children.forEach { renderChild(it) }
        } else {
            c.strList("items").forEach { item ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("•")
                    Text(item, style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
    }
}

@Composable
private fun TablePrimitive(
    c: Component,
    emit: Emit,
) {
    val headers = c.strList("headers")
    val rows = c.rows("rows")
    val total = c.int("total_rows")
    val size = c.int("page_size")
    val offset = c.int("page_offset") ?: 0
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val bodyStyle = MaterialTheme.typography.bodySmall
    val headerStyle = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold)
    val columnCount = maxOf(headers.size, rows.maxOfOrNull { it.size } ?: 0)
    val widths =
        remember(headers, rows, density, bodyStyle, headerStyle) {
            List(columnCount) { index ->
                val texts = rows.map { it.getOrNull(index).orEmpty() }
                val bodyWidth = texts.maxOfOrNull { measurer.measure(it, style = bodyStyle).size.width } ?: 0
                val headerWidth = measurer.measure(headers.getOrNull(index).orEmpty(), style = headerStyle).size.width
                with(density) { maxOf(bodyWidth, headerWidth).toDp() }.coerceAtLeast(72.dp) + 24.dp
            }
        }
    Column(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).testTag("table-scroll")) {
            if (headers.isNotEmpty()) {
                Row(modifier = Modifier.padding(vertical = 4.dp)) {
                    headers.forEachIndexed { index, h ->
                        Text(
                            h,
                            modifier = Modifier.width(widths[index]).padding(horizontal = 12.dp),
                            maxLines = 1,
                            fontWeight = FontWeight.SemiBold,
                            style = MaterialTheme.typography.labelMedium,
                        )
                    }
                }
                HorizontalDivider()
            }
            rows.forEach { row ->
                Row(modifier = Modifier.padding(vertical = 4.dp)) {
                    row.forEachIndexed { index, cell ->
                        Text(
                            cell,
                            modifier = Modifier.width(widths[index]).padding(horizontal = 12.dp),
                            maxLines = 1,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }
        }
        // A server-paginated table (total_rows + page_size) gets a pager row; the
        // reply is a ui_upsert keyed to this component_id, updating it in place.
        if (shouldPaginate(total, size)) {
            val ps = pagerState(total!!, size!!, offset)
            TablePager(
                state = ps,
                onPrev = { emit.event("table_paginate", paginatePayload(c.id, offset - size, size)) },
                onNext = { emit.event("table_paginate", paginatePayload(c.id, offset + size, size)) },
            )
        }
    }
}

/** "‹ Prev · rows X–Y of Z · Next ›" — the pager row for a paginated table (T027). */
@Composable
private fun TablePager(
    state: PagerState,
    onPrev: () -> Unit,
    onNext: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        TextButton(onClick = onPrev, enabled = state.prevEnabled) { Text("‹ Prev") }
        Text(
            state.label,
            modifier = Modifier.weight(1f),
            textAlign = TextAlign.Center,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        TextButton(onClick = onNext, enabled = state.nextEnabled) { Text("Next ›") }
    }
}

/** The `table_paginate` payload: {component_id, params:{page_offset, page_size}}. */
private fun paginatePayload(
    componentId: String?,
    offset: Int,
    size: Int,
): JsonObject =
    buildJsonObject {
        if (componentId != null) put("component_id", componentId)
        putJsonObject("params") {
            put("page_offset", offset.coerceAtLeast(0))
            put("page_size", size)
        }
    }

@Composable
private fun TabsPrimitive(
    c: Component,
    renderChild: @Composable (Component) -> Unit,
) {
    val tabs = c.arr("tabs")?.mapNotNull { it as? JsonObject } ?: emptyList()
    if (tabs.isEmpty()) return
    var selected by remember { mutableIntStateOf(0) }
    Column {
        TabRow(selectedTabIndex = selected.coerceIn(0, tabs.size - 1)) {
            tabs.forEachIndexed { i, tab ->
                Tab(
                    selected = i == selected,
                    onClick = { selected = i },
                    text = { Text((tab["label"] as? JsonPrimitive)?.contentOrNull ?: "Tab ${i + 1}") },
                )
            }
        }
        val current = tabs.getOrNull(selected) ?: tabs.first()
        Column(modifier = Modifier.padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Component.listFromJson(current["content"] as? JsonArray).forEach { renderChild(it) }
        }
    }
}

@Composable
private fun ChatHistoryPrimitive(
    c: Component,
    emit: Emit,
) {
    val items = c.arr("items").orEmpty().mapNotNull { (it as? JsonObject)?.let(ChatSummary::fromHistoryItem) }
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (items.isEmpty()) {
            HistoryEmpty()
        } else {
            val title =
                (c.attributes["title"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                    ?.takeIf { it.isNotEmpty() } ?: "Recent chats"
            HistoryHeader(title, items.size)
            items.forEach { chat -> HistoryRow(chat) { emit.event("load_chat", buildJsonObject { put("chat_id", it) }) } }
        }
    }
}

@Composable
private fun SkeletonPrimitive(c: Component) {
    // A `skeleton` is a LOADING placeholder. The native canvas commits only FINAL
    // content (the app shows its own skeleton while a query is in flight), so a
    // skeleton reaching the canvas is stray — a placeholder the model never filled.
    // Render nothing rather than dead gray bars. (The reducer also drops top-level
    // skeletons so they leave no gap; this handles any nested ones.)
}
