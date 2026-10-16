// Retains installed local speech proofs for the Android adapter and validates the exact voice
// selected for each playout against the current engine inventory.

package com.personalailabs.astraldeep.app.voice

import java.util.Locale

internal fun recognitionInstallation(
    apiLevel: Int,
    installed: List<String>,
    pending: List<String>,
    supported: List<String>,
    locale: String = "en-US",
): String {
    if (apiLevel < 33) return "unavailable"

    fun List<String>.includesLocale(): Boolean = any { Locale.forLanguageTag(it) == Locale.forLanguageTag(locale) }
    return when {
        installed.includesLocale() -> "ready"
        pending.includesLocale() -> "installing"
        supported.includesLocale() -> "downloadable"
        else -> "unavailable"
    }
}

internal data class LocalSynthesisVoice(
    val name: String,
    val locale: String,
    val requiresNetwork: Boolean,
    val installed: Boolean,
) {
    fun usable(configuredLocale: String): Boolean =
        installed && !requiresNetwork && Locale.forLanguageTag(locale) == Locale.forLanguageTag(configuredLocale)
}

internal class LocalSynthesisProof {
    private var proven: LocalSynthesisVoice? = null

    fun observe(
        voices: Collection<LocalSynthesisVoice>,
        locale: String,
    ): Boolean {
        proven = voices.filter { it.usable(locale) }.minByOrNull { it.name }
        return proven != null
    }

    fun selectForPlayout(
        voices: Collection<LocalSynthesisVoice>,
        locale: String,
        select: (String) -> Boolean,
        selected: () -> LocalSynthesisVoice?,
    ): Boolean {
        val voice = proven ?: return false
        if (!voice.usable(locale) || voice !in voices || !select(voice.name)) return false
        return selected() == voice
    }
}
