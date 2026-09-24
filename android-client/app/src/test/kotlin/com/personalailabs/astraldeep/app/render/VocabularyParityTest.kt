// Tests that Android's rendered component vocabulary matches the committed ui_protocol.json manifest, so a
// backend vocabulary change fails until the app renders or deliberately excludes the new type.

package com.personalailabs.astraldeep.app.render

import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class VocabularyParityTest {
    private val excluded = setOf("audio", "generative")

    private fun manifestComponentTypes(): Set<String> {
        var dir: File? = File(".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "contracts/ui_protocol.json")
            if (candidate.isFile) {
                val root = Json.parseToJsonElement(candidate.readText()).jsonObject
                return root.getValue("component_types").jsonArray
                    .map { it.jsonPrimitive.content }
                    .toSet()
            }
            dir = dir.parentFile
        }
        error("contracts/ui_protocol.json not found walking up from ${File(".").absolutePath}")
    }

    private fun renderer() = Renderer(Emit { _, _ -> }).registerAllRenderers()

    @Test
    fun registers_exactly_the_backend_vocabulary_minus_exclusions() {
        assertEquals(manifestComponentTypes() - excluded, renderer().supportedTypes)
    }

    @Test
    fun excludes_web_only_or_unimplemented_types() {
        val supported = renderer().supportedTypes
        excluded.forEach { assertTrue(it !in supported, "$it must not be advertised") }
    }

    @Test
    fun excluded_types_are_real_backend_types() {
        assertTrue(excluded.all { it in manifestComponentTypes() })
    }
}
