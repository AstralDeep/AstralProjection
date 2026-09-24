// Tests for ParamPicker's visible_when field-visibility rule: a field shows only while its named controller
// field's current or default value matches, re-evaluated on every change.

package com.personalailabs.astraldeep.app.render.renderers

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ParamVisibleWhenTest {
    private fun field(json: String): JsonObject = Json.parseToJsonElement(json) as JsonObject

    private val credType =
        field(
            """{"name":"cred_type","label":"Credential type","kind":"select",
               "options":["ssh_key","password"],"default":"ssh_key"}""",
        )
    private val privateKey =
        field(
            """{"name":"private_key","label":"Private key","kind":"textarea",
               "visible_when":{"field":"cred_type","equals":"ssh_key","default":"ssh_key"}}""",
        )
    private val passphrase =
        field(
            """{"name":"passphrase","label":"Key passphrase","kind":"password",
               "visible_when":{"field":"cred_type","equals":"ssh_key","default":"ssh_key"}}""",
        )
    private val password =
        field(
            """{"name":"password","label":"Password","kind":"password",
               "visible_when":{"field":"cred_type","equals":"password","default":"ssh_key"}}""",
        )
    private val form = listOf(credType, privateKey, passphrase, password)

    @Test
    fun initial_visibility_follows_the_controller_default() {
        val texts = initialTexts(form)
        assertEquals("ssh_key", texts["cred_type"])
        assertTrue(fieldIsVisible(privateKey, texts), "ssh_key fields start visible")
        assertTrue(fieldIsVisible(passphrase, texts))
        assertFalse(fieldIsVisible(password, texts), "the password field starts hidden")
    }

    @Test
    fun visibility_reacts_to_controller_change_both_ways() {
        val texts = initialTexts(form).toMutableMap()
        texts["cred_type"] = "password"
        assertFalse(fieldIsVisible(privateKey, texts), "key textarea hides for password auth")
        assertFalse(fieldIsVisible(passphrase, texts))
        assertTrue(fieldIsVisible(password, texts))
        texts["cred_type"] = "ssh_key"
        assertTrue(fieldIsVisible(privateKey, texts), "flipping back restores the key fields")
        assertTrue(fieldIsVisible(passphrase, texts))
        assertFalse(fieldIsVisible(password, texts))
    }

    @Test
    fun hidden_fields_still_submit_their_values() {
        val texts = initialTexts(form).toMutableMap()
        texts["private_key"] = "KEYDATA"
        texts["cred_type"] = "password"
        val payload = collectFields(form, texts, emptyMap(), emptyMap())
        val fields = payload["fields"] as JsonObject
        assertEquals(
            "KEYDATA",
            (fields["private_key"] as JsonPrimitive).content,
            "hidden fields keep submitting (server picks by cred_type)",
        )
        assertEquals("password", (fields["cred_type"] as JsonPrimitive).content)
    }

    @Test
    fun a_payload_without_visible_when_renders_everything() {
        val legacy = form.map { f -> JsonObject(f.filterKeys { it != "visible_when" }) }
        val texts = initialTexts(legacy)
        assertTrue(legacy.all { fieldIsVisible(it, texts) })
    }

    @Test
    fun an_untouched_controller_resolves_via_the_embedded_default() {
        assertTrue(fieldIsVisible(privateKey, emptyMap()))
        assertFalse(fieldIsVisible(password, emptyMap()))
    }
}
