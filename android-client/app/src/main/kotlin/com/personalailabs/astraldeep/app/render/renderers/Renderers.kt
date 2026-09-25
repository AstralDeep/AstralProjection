// Registers the full native SDUI renderer vocabulary in one call so ROTE doesn't degrade agent-emitted
// Plotly/content into fallback cards; a few web-only types are intentionally left unregistered.

package com.personalailabs.astraldeep.app.render.renderers

import com.personalailabs.astraldeep.app.render.Renderer

fun Renderer.registerAllRenderers(): Renderer =
    registerBasicRenderers()
        .registerLayoutRenderers()
        .registerDataRenderers()
        .registerInputRenderers()
        .registerChartRenderers()
        .registerCompositeRenderers()
        .registerMediaRenderers()
