// Exercises the proof consumed by AndroidLocalSpeechEngine with unavailable language models,
// cloud defaults, missing voices, and engines that refuse or substitute the selected voice.

package com.personalailabs.astraldeep.app.voice

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LocalSpeechProofTest {
    private val offline = LocalSynthesisVoice("offline", "en-US", false, true)
    private val cloud = LocalSynthesisVoice("cloud", "en-US", true, true)

    @Test
    fun recognitionRequiresApi33AndInstalledConfiguredLocale() {
        assertEquals("unavailable", recognitionInstallation(32, listOf("en-US"), emptyList(), emptyList()))
        assertEquals("unavailable", recognitionInstallation(33, listOf("en-GB"), emptyList(), emptyList()))
        assertEquals("downloadable", recognitionInstallation(33, emptyList(), emptyList(), listOf("en-US")))
        assertEquals("installing", recognitionInstallation(33, emptyList(), listOf("en-US"), listOf("en-US")))
        assertEquals("ready", recognitionInstallation(33, listOf("en-US"), emptyList(), emptyList()))
    }

    @Test
    fun cloudDefaultIsReplacedByTheExactProvenOfflineVoice() {
        val proof = LocalSynthesisProof()
        val voices = listOf(cloud, offline)
        assertTrue(proof.observe(voices, "en-US"))
        var selected = cloud
        assertTrue(
            proof.selectForPlayout(voices, "en-US", { name ->
                selected = voices.single { it.name == name }
                true
            }, { selected }),
        )
        assertEquals(offline, selected)
    }

    @Test
    fun unprovedUnavailableAndSubstitutedVoicesNeverPlay() {
        val proof = LocalSynthesisProof()
        assertFalse(proof.observe(listOf(cloud, offline.copy(installed = false)), "en-US"))
        assertFalse(proof.selectForPlayout(listOf(offline), "en-US", { error("no proof") }, { offline }))
        assertTrue(proof.observe(listOf(offline), "en-US"))
        assertFalse(proof.selectForPlayout(emptyList(), "en-US", { error("voice removed") }, { offline }))
        assertFalse(proof.selectForPlayout(listOf(offline), "fr-FR", { error("wrong locale") }, { offline }))
        assertFalse(proof.selectForPlayout(listOf(offline), "en-US", { false }, { offline }))
        assertFalse(proof.selectForPlayout(listOf(offline), "en-US", { true }, { cloud }))
        assertFalse(proof.selectForPlayout(listOf(offline.copy(requiresNetwork = true)), "en-US", { error("changed proof") }, { cloud }))
    }
}
