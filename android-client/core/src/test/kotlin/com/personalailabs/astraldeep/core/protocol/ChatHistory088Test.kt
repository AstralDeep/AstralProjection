package com.personalailabs.astraldeep.core.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull

class ChatHistory088Test {
    @Test
    fun canonical_rows_preserve_server_metadata_and_display_css_whitespace_as_plain_text() {
        val row = ChatSummary.fromHistoryItem(Json.parseToJsonElement("""{"chat_id":"one","title":" \t\n","preview":"\n\n<script>Alpha</script>\tBeta\fGamma\r\n","time":"server time","icon":"📝","saved":true}""").jsonObject)!!
        assertEquals("Untitled chat", row.displayTitle)
        assertEquals("<script>Alpha</script> Beta Gamma", row.displayPreview)
        assertEquals("📝", row.serverIcon)
        assertEquals("server time", row.relativeTime(Instant.EPOCH))
        assertEquals(true, row.hasSavedComponents)
        assertEquals("a\u00a0b", ChatSummary.displayText("a\u00a0b"))
        assertEquals("a\u00a0b", ChatSummary.displayText("\u0085\u00a0 a\u00a0b \u2003"))
        for (id in listOf("null", "{}", "1", "true", "\" \t\"".replace("\t", "\\t"))) {
            assertNull(ChatSummary.fromHistoryItem(Json.parseToJsonElement("""{"chat_id":$id,"title":"bad"}""").jsonObject))
        }
        val bad = ChatSummary.fromHistoryItem(Json.parseToJsonElement("""{"id":"alias","title":{},"preview":false,"icon":1,"time":{},"saved":"true"}""").jsonObject)!!
        assertEquals("Untitled chat", bad.displayTitle)
        assertEquals("", bad.displayPreview)
        assertEquals(null, bad.serverIcon)
        assertEquals("", bad.relativeTime())
        assertEquals(false, bad.hasSavedComponents)
    }

    @Test
    fun history_rejects_every_scope_field_even_when_null_or_partial() {
        for (key in listOf("chat_id", "chatId", "connection_generation", "request_generation", "base_render_revision", "frame_sequence")) {
            for (value in listOf(JsonNull, Json.parseToJsonElement("\"malformed\""))) {
                val frame =
                    buildJsonObject {
                        put("type", "ui_render")
                        put("target", "history")
                        put("components", Json.parseToJsonElement("[]"))
                        put(key, value)
                    }
                assertIs<Inbound.Unknown>(Wire.decode(frame.toString()), key)
            }
        }
    }

    @Test
    fun history_preserves_plain_preview_and_strict_saved_flag() {
        val result = assertIs<Inbound.HistoryList>(Wire.decode("""{"type":"history_list","chats":[{"id":"one","title":"New Chat","preview":"<script>plain text</script>","updated_at":1700000000000,"has_saved_components":true},{"id":"two","title":"Old chat"},{"id":"three","preview":{},"has_saved_components":"true"}]}"""))
        assertEquals("<script>plain text</script>", result.chats[0].preview)
        assertEquals("1700000000000", result.chats[0].updatedAt)
        assertEquals(true, result.chats[0].hasSavedComponents)
        assertEquals(ChatSummary("two", "Old chat"), result.chats[1])
        assertEquals("", result.chats[2].preview)
        assertEquals(false, result.chats[2].hasSavedComponents)
    }

    @Test
    fun relative_labels_match_web_for_units_boundaries_and_bad_timestamps() {
        val now = Instant.ofEpochSecond(1_700_000_000)
        for ((age, label) in listOf(-60L to "just now", 44L to "just now", 120L to "2m", 7200L to "2h", 172800L to "2d", 1209600L to "2w", 5259600L to "2mo", 63115200L to "2y")) {
            for (scale in listOf(1L, 1000L)) {
                val value = ((now.epochSecond - age) * scale).toString()
                assertEquals(label, ChatSummary("c", "", updatedAt = value).relativeTime(now))
            }
        }
        for (value in listOf("", "not a timestamp", "NaN", "Infinity", "-1e308")) {
            assertEquals("", ChatSummary("c", "", updatedAt = value).relativeTime(now))
        }
    }
}
