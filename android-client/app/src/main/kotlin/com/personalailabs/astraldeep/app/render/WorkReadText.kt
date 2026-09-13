package com.personalailabs.astraldeep.app.render

import androidx.compose.runtime.compositionLocalOf

/** Text in a validated Work or Private notes surface is literal, including nested components. */
internal val LocalWorkReadText = compositionLocalOf { false }

/** Shared note forms use an exact equality-map visibility condition. */
internal val LocalGuidanceNotes = compositionLocalOf { false }
