// Carries current surface operation outcomes into form renderers without replacing edited field values.
package com.personalailabs.astraldeep.app.render

import androidx.compose.runtime.staticCompositionLocalOf

data class FormSubmissionState(
    val connected: Boolean = true,
    val pending: Boolean = false,
    val reloadRequired: Boolean = false,
    val outcomeRevision: Long = 0,
    val error: String? = null,
)

internal val LocalFormSubmissionState = staticCompositionLocalOf { FormSubmissionState() }
