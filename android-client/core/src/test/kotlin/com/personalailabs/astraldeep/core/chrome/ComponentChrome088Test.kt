package com.personalailabs.astraldeep.core.chrome

import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ComponentChrome088Test {
    private fun component(body: String): Component = Component.fromJson(Json.parseToJsonElement(body) as JsonObject)

    private fun action(
        kind: String,
        context: String = if (kind in listOf("csv", "share")) "owned_chat" else "live_canvas",
    ) =
        """{"kind":"$kind","label":"$kind","icon":"↗","title":"Action $kind","context":"$context"}"""

    private fun chrome(
        actions: String,
        version: String = "1",
    ) = component("""{"type":"table","component_id":"wc_a","component_chrome":{"version":$version,"actions":[$actions]}}""")

    @Test fun canonical_order_and_exact_integer_numbers_preserve_server_text() {
        val values = ComponentChrome.actions(chrome(listOf("share", "csv", "history", "refine").joinToString(",") { action(it) }, "1.0"))
        assertEquals(listOf("refine", "history", "csv", "share"), values.map { it.kind })
        assertEquals("Action share", values.last().title)
        assertEquals("↗", values.last().icon)
    }

    @Test fun missing_unknown_or_malformed_metadata_has_no_fallback() {
        for (value in listOf("null", "true", "{}", "[]", "1", "\"text\"")) {
            assertTrue(ComponentChrome.actions(component("""{"type":"table","id":"wc_a","component_chrome":$value}""")).isEmpty())
        }
        for (version in listOf("true", "null", "\"1\"", "2", "1.1", "1e999")) assertTrue(ComponentChrome.actions(chrome(action("csv"), version)).isEmpty())
        assertTrue(ComponentChrome.actions(chrome(List(17) { action("csv") }.joinToString(","))).isEmpty())
        assertTrue(ComponentChrome.actions(component("""{"type":"table","id":"wc_a"}""")).isEmpty())
    }

    @Test fun unknown_invalid_and_all_duplicate_known_entries_are_individually_omitted() {
        val bad = action("history").dropLast(1) + ",\"event\":\"attack\"}"
        assertEquals(listOf("csv"), ComponentChrome.actions(chrome("$bad,${action("history")},${action("csv")},${action("refine", "owned_chat")},null,${action("future")}")).map { it.kind })
        assertEquals(listOf("refine"), ComponentChrome.actions(chrome("${action("share")},${action("refine")},${action("share")}")).map { it.kind })
    }

    @Test fun unicode_limits_count_codepoints_without_truncation() {
        val valid = action("share").replace("\"label\":\"share\"", "\"label\":\"${"😀".repeat(96)}\"")
        assertEquals(1, ComponentChrome.actions(chrome(valid)).size)
        for (entry in listOf(valid.replace("😀", "😀😀"), action("share").replace("↗", "😀".repeat(9)), action("share").replace("Action share", "x".repeat(161)), action("share").replace("\"label\":\"share\"", "\"label\":false"))) {
            assertTrue(ComponentChrome.actions(chrome(entry)).isEmpty())
        }
    }

    @Test fun version_rows_are_bounded_unique_server_metadata_only() {
        fun row(number: String) = """{"version_no":$number,"reason":"refine","created_at":"2026-09-12T12:34:00Z","title":"Earlier"}"""

        fun parse(rows: String) = ComponentChrome.versions(component("""{"type":"table","versions":[$rows]}"""))
        val valid = parse(row("9007199254740991.0")).single()
        assertEquals(9007199254740991L, valid.versionNo)
        assertEquals("v9007199254740991 · Earlier · 2026-09-12 12:34", valid.label)
        for (n in listOf("0", "-1", "9007199254740992", "1.5", "true", "\"1\"")) assertTrue(parse(row(n)).isEmpty())
        assertTrue(parse("${row("1")},${row("1")}").isEmpty())
        assertEquals(5, parse(List(6) { row("${it + 1}") }.joinToString(",")).size)
        assertEquals("x".repeat(120), parse(row("1").replace("Earlier", "x".repeat(121))).single().title)
        assertTrue(parse("{}").isEmpty())
        assertEquals("v1", parse("""{"version_no":1,"reason":"","created_at":"","title":""}""").single().label)
    }

    @Test fun action_identity_uses_canonical_component_id_without_coercing_a_layout_alias() {
        assertEquals("wc_a", ComponentChrome.identity(chrome(action("refine"))))
        val canonical = component("""{"type":"text","component_id":"b","id":"a"}""")
        assertEquals("b", canonical.id)
        assertEquals("b", ComponentChrome.identity(canonical))
        assertNull(ComponentChrome.identity(canonical.copy(id = "a")))
        for (body in listOf(
            "\"id\":\"a\"",
            "\"component_id\":4,\"id\":\"a\"",
            "\"component_id\":null,\"id\":\"a\"",
            "\"component_id\":\"\"",
            "\"component_id\":\" \"",
            "\"component_id\":\"a\\n\"",
            "\"component_id\":\"${"x".repeat(129)}\"",
        )) {
            assertNull(ComponentChrome.identity(component("""{"type":"text",$body}""")))
        }
    }

    @Test fun nonempty_plain_action_text_and_null_version_text_match_server_normalization() {
        assertEquals(" ", ComponentChrome.actions(chrome(action("share").replace("\"label\":\"share\"", "\"label\":\" \""))).single().label)
        val value = component("""{"type":"text","versions":[{"version_no":1,"title":null,"reason":null,"created_at":null}]}""")
        assertEquals(ComponentVersion(1, "", "", ""), ComponentChrome.versions(value).single())
    }
}
