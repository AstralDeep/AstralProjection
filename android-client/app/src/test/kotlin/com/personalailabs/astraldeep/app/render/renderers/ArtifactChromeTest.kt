package com.personalailabs.astraldeep.app.render.renderers

import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Feature 055 US4/US5 (T036/T040/T045) — the pure rules behind the shared
 * per-component chrome: provenance badge mapping (server-stamped field only,
 * absent = nothing), overflow-menu derivation (Refine target + export
 * entries with their exact REST URLs), and the `component_refine` payload.
 */
class ArtifactChromeTest {
    private fun comp(json: String): Component = Component.fromJson(Json.parseToJsonElement(json) as JsonObject)

    // --- provenance badge (T036, wire-contract §6) ---------------------------

    @Test
    fun the_three_canonical_stamps_map_to_their_badges() {
        assertEquals(Provenance.Grounded, provenanceOf(comp("""{"type":"card","provenance":"grounded"}""")))
        assertEquals(Provenance.Estimated, provenanceOf(comp("""{"type":"card","provenance":"estimated"}""")))
        assertEquals(Provenance.Generated, provenanceOf(comp("""{"type":"card","provenance":"generated"}""")))
    }

    @Test
    fun web_footer_synonyms_normalize_to_the_same_marks() {
        assertEquals(Provenance.Grounded, provenanceOf(comp("""{"type":"card","provenance":"verified"}""")))
        assertEquals(Provenance.Estimated, provenanceOf(comp("""{"type":"card","provenance":"low_confidence"}""")))
        assertEquals(Provenance.Generated, provenanceOf(comp("""{"type":"card","provenance":"AI"}""")))
    }

    @Test
    fun absent_blank_or_unknown_values_render_nothing() {
        assertNull(provenanceOf(comp("""{"type":"card"}""")))
        assertNull(provenanceOf(comp("""{"type":"card","provenance":"  "}""")))
        assertNull(provenanceOf(comp("""{"type":"card","provenance":"gospel"}""")))
    }

    @Test
    fun decorative_types_are_never_badged_even_when_stamped() {
        assertNull(provenanceOf(comp("""{"type":"divider","provenance":"grounded"}""")))
        assertNull(provenanceOf(comp("""{"type":"skeleton","provenance":"generated"}""")))
    }

    @Test
    fun filenames_are_safe_and_refine_payload_contains_only_the_instruction() {
        assertEquals("a_b_c.csv", exportFilename("a/b\\c", "csv"))
        assertEquals("export.html", exportFilename("   ", "html"))
        assertEquals("make it a bar chart", (refinePayload("  make it a bar chart  ")["instruction"] as JsonPrimitive).content)
        assertEquals(setOf("instruction"), refinePayload("x").keys)
    }
}
