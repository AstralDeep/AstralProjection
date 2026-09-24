// Two CompositionLocals: work/private-notes surfaces render text literally (no markdown), and guidance-note
// forms use an exact equality-map visibility rule.

package com.personalailabs.astraldeep.app.render

import androidx.compose.runtime.compositionLocalOf

internal val LocalWorkReadText = compositionLocalOf { false }

internal val LocalGuidanceNotes = compositionLocalOf { false }
