// Tests for ParamPicker field rendering rules (select/checklist/etc.) against the exact shapes
// webrender/chrome/surfaces/llm.py emits, guarding against fields silently degrading to plain text.

package com.personalailabs.astraldeep.app.render.renderers

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ParamPickerFieldsTest {
    private fun field(json: String): JsonObject = Json.parseToJsonElement(json) as JsonObject

    private val provider =
        field(
            """{"name":"provider","label":"Provider","kind":"select","default":"openai",
               "options":["openai","anthropic","xai","ollama"]}""",
        )

    private fun fieldsOf(payload: JsonObject): JsonObject = payload["fields"] as JsonObject

    private fun str(
        payload: JsonObject,
        name: String,
    ): String = (fieldsOf(payload)[name] as JsonPrimitive).content

    private fun list(
        payload: JsonObject,
        name: String,
    ): List<String> = (fieldsOf(payload)[name] as JsonArray).map { (it as JsonPrimitive).content }

    @Test
    fun a_select_with_options_renders_a_dropdown_preselecting_the_default() {
        assertTrue(rendersAsDropdown(provider))
        assertEquals(listOf("openai", "anthropic", "xai", "ollama"), fieldOptions(provider))
        assertEquals("openai", initialTexts(listOf(provider))["provider"])
    }

    @Test
    fun labeled_options_display_a_dropdown_and_submit_saved_keys() {
        val saved =
            field(
                """{"name":"provider","kind":"select","default":"custom",
                "options":[{"value":"openai","label":"OpenAI"},
                {"value":"custom","label":"Custom OpenAI-compatible endpoint"}]}""",
            )
        assertTrue(rendersAsDropdown(saved))
        assertEquals(listOf("openai", "custom"), fieldOptions(saved))
        val fields = listOf(saved)
        val payload = collectFields(fields, initialTexts(fields), initialBools(fields), initialChecks(fields))
        assertEquals("custom", str(payload, "provider"))
    }

    @Test
    fun labeled_checklists_keep_saved_keys_and_server_order() {
        val selected =
            field(
                """{"name":"tools","kind":"checklist","default":["write"],
                "options":[{"value":"read","label":"Read files"},
                {"value":"write","label":"Write files"}]}""",
            )
        val fields = listOf(selected)
        val payload = collectFields(fields, initialTexts(fields), initialBools(fields), initialChecks(fields))
        assertEquals(listOf("write"), list(payload, "tools"))
    }

    @Test
    fun a_default_that_is_not_on_the_menu_falls_back_to_the_first_option() {
        val opts = listOf("openai", "xai")
        assertEquals("openai", selectInitial("gone-provider", opts))
        assertEquals("openai", selectInitial("", opts))
        assertEquals("openai", selectInitial(null, opts))
    }

    @Test
    fun a_select_without_options_retains_a_selectable_saved_default() {
        val f = field("""{"name":"provider","kind":"select","default":"openai"}""")
        assertTrue(rendersAsDropdown(f))
        assertEquals("openai", initialTexts(listOf(f))["provider"])
        assertFalse(rendersAsDropdown(field("""{"name":"p","kind":"select","options":[]}""")))
    }

    @Test
    fun selecting_an_option_submits_that_key_verbatim() {
        val picked = mapOf("provider" to "xai")
        val payload = collectFields(listOf(provider), picked, emptyMap(), emptyMap())
        assertEquals("xai", str(payload, "provider"))
        assertTrue((fieldsOf(payload)["provider"] as JsonPrimitive).isString)
    }

    @Test
    fun an_untouched_form_submits_the_preselected_key() {
        val fields = listOf(provider)
        val payload = collectFields(fields, initialTexts(fields), initialBools(fields), initialChecks(fields))
        assertEquals("openai", str(payload, "provider"))
    }

    private val tools =
        field(
            """{"name":"tools","label":"Tools","kind":"checklist","default":["read","write"],
               "options":["read","write","exec"]}""",
        )

    @Test
    fun a_checklist_submits_a_list_of_keys_in_server_order() {
        val payload = collectFields(listOf(tools), emptyMap(), emptyMap(), mapOf("tools" to setOf("exec", "read")))
        assertEquals(listOf("read", "exec"), list(payload, "tools"))
    }

    @Test
    fun a_checklist_default_keeps_saved_keys_missing_from_the_refreshed_catalog() {
        assertEquals(setOf("read", "write"), initialChecks(listOf(tools))["tools"])
        val stale = field("""{"name":"tools","kind":"checklist","default":["gone"],"options":["read"]}""")
        assertEquals(setOf("gone"), initialChecks(listOf(stale))["tools"])
        assertEquals(listOf("read", "gone"), fieldOptions(stale))
        assertFalse(initialTexts(listOf(tools)).containsKey("tools"))
    }

    @Test
    fun saved_scalar_and_array_choices_submit_without_catalog_replacement() {
        val saved = field("""{"name":"provider","kind":"select","default":"saved","options":["openai"]}""")
        val checklist = field("""{"name":"tools","kind":"checklist","default":["old","write"],"options":["read"]}""")
        val fields = listOf(saved, checklist)
        val payload = collectFields(fields, initialTexts(fields), initialBools(fields), initialChecks(fields))
        assertEquals("saved", str(payload, "provider"))
        assertEquals(listOf("old", "write"), list(payload, "tools"))
    }

    @Test
    fun an_empty_checklist_selection_still_submits_an_array_not_a_string() {
        val payload = collectFields(listOf(tools), emptyMap(), emptyMap(), emptyMap())
        assertEquals(emptyList(), list(payload, "tools"))
    }

    @Test
    fun booleans_texts_and_the_action_payload_keep_their_shapes() {
        val fields =
            listOf(
                field("""{"name":"on","kind":"boolean","default":true}"""),
                field("""{"name":"base_url","kind":"text","default":"https://x"}"""),
                field("""{"name":"api_key","kind":"password"}"""),
                provider,
            )
        val payload =
            collectFields(
                fields,
                initialTexts(fields),
                initialBools(fields),
                initialChecks(fields),
                buildJsonObject { put("agent_id", "a1") },
            )
        assertEquals(true, (fieldsOf(payload)["on"] as JsonPrimitive).booleanOrNull)
        assertEquals("https://x", str(payload, "base_url"))
        assertEquals("", str(payload, "api_key"))
        assertEquals("openai", str(payload, "provider"))
        assertEquals("a1", (payload["agent_id"] as JsonPrimitive).content)
    }
}
