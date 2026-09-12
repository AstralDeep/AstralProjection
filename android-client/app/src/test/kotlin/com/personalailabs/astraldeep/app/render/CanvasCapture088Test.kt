package com.personalailabs.astraldeep.app.render

import com.personalailabs.astraldeep.app.auth.ConversationResumeStore
import com.personalailabs.astraldeep.app.ui.WorkspaceContext
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CanvasCapture088Test {
    private val context = WorkspaceContext(ConversationResumeStore.AccountIdentity("issuer", "owner"), 1, "chat", 2u, setOf("export_canvas"))
    private val theme = listOf("bg", "surface", "surface2", "border", "primary", "secondary", "accent", "text", "muted", "success", "warning", "error", "info").associateWith { "#112233" }

    private fun components(raw: String) = Component.listFromJson(Json.parseToJsonElement(raw) as JsonArray)

    private fun bind(
        registry: CanvasCaptureRegistry,
        raw: String,
    ) = registry.bind(context, components(raw), 296, 640, theme)

    @Test fun selectedPaneAndDisclosureAreCapturedWithoutHiddenContentOrActions() =
        runTest {
            val registry = CanvasCaptureRegistry()
            bind(registry, """[{"type":"tabs","id":"t","tabs":[{"label":"Hidden","content":[{"type":"image","url":"https://secret.invalid"}]},{"label":"Visible","children":[{"type":"collapsible","id":"c","content":[{"type":"text","content":"visible","token":"secret"},{"type":"button","action":"effect","payload":{"secret":1}}]}]}]}]""")
            registry.select("/components/0", 1)
            registry.expand("/components/0/tabs/1/children/0", true)
            val capture = registry.freeze(context)
            val value = capture.presentation.toString()
            assertTrue(value.contains("visible"))
            assertFalse(value.contains("secret"))
            assertFalse(value.contains("effect"))
            assertTrue(value.contains("/components/0/tabs/1/children/0"))
            assertTrue(registry.isCurrent(capture, context))
            registry.expand("/components/0/tabs/1/children/0", false)
            assertFalse(registry.isCurrent(capture, context))
        }

    @Test fun missingPixelsAndUnmeasuredGridRefuseRatherThanGuess() =
        runTest {
            for (raw in listOf("""[{"type":"image","url":"https://unloaded.invalid"}]""", """[{"type":"grid","columns":8,"content":[]}]""", """[{"type":"plotly_chart","data":[]}]""")) {
                val registry = CanvasCaptureRegistry()
                bind(registry, raw)
                assertTrue(runCatching { registry.freeze(context) }.isFailure)
            }
        }

    @Test fun retainedPixelsAndMeasuredGridSurviveUnmountAndExactRebind() =
        runTest {
            val registry = CanvasCaptureRegistry()
            val raw = """[{"type":"grid","columns":8,"content":[{"type":"image","id":"i","url":"https://source.invalid","headers":{"Authorization":"secret"}}]}]"""
            bind(registry, raw)
            registry.columns("/components/0", 2)
            registry.imageSize("/components/0/content/0", 144.5, 80.25)
            registry.pixels("/components/0/content/0", CanvasPixels { "data:image/png;base64,cGl4ZWxz" })
            registry.unmount()
            bind(registry, raw)
            val capture = registry.freeze(context)
            assertTrue(capture.presentation.toString().contains("\"columns\":2"))
            assertFalse(capture.presentation.toString().contains("source.invalid"))
            assertFalse(capture.presentation.toString().contains("secret"))
            assertEquals(1, (capture.presentation["images"] as JsonArray).size)
            registry.clear()
            assertFalse(registry.isCurrent(capture, context))
            bind(registry, raw)
            assertTrue(runCatching { registry.freeze(context) }.isFailure)
        }

    @Test fun delayedPixelsCannotCrossOwnerOrComponentGeneration() =
        runTest {
            for (ownerChange in listOf(false, true)) {
                val registry = CanvasCaptureRegistry()
                val raw = """[{"type":"image","id":"same","url":"https://source.invalid"}]"""
                bind(registry, raw)
                registry.imageSize("/components/0", 296.0, 120.0)
                val started = CompletableDeferred<Unit>()
                val result = CompletableDeferred<String>()
                registry.pixels(
                    "/components/0",
                    CanvasPixels {
                        started.complete(Unit)
                        result.await()
                    },
                )
                val pending = async { runCatching { registry.freeze(context) } }
                started.await()
                if (ownerChange) {
                    registry.bind(context.copy(epoch = 2), components(raw), 296, 640, theme)
                } else {
                    bind(registry, raw.replace("source.invalid", "replacement.invalid"))
                }
                result.complete("data:image/png;base64,cGl4ZWxz")
                assertTrue(pending.await().isFailure)
            }
        }

    @Test fun invalidAliasesAndAuthoredStyleRefuseWithoutEchoingInput() =
        runTest {
            for (raw in listOf("""[{"type":"container","content":[],"children":[]}]""", """[{"type":"card","content":{"type":"text","content":"private"}}]""", """[{"type":"text","content":"private","css":{"color":"red"}}]""")) {
                val registry = CanvasCaptureRegistry()
                bind(registry, raw)
                val failure = runCatching { registry.freeze(context) }.exceptionOrNull()
                assertNotNull(failure)
                assertFalse(failure.toString().contains("private"))
            }
        }

    @Test fun streamingChildrenAndDisplayedReplacementsOverrideStaleRawChildLists() =
        runTest {
            val registry = CanvasCaptureRegistry()
            val visible = components("""[{"type":"text","content":"Actual streamed content"}]""")
            val container = Component("container", "stream1", JsonObject(mapOf("type" to JsonPrimitive("container"))), visible)
            registry.bind(context, listOf(container), 296, 640, theme)
            val first = registry.freeze(context).presentation.toString()
            assertTrue(first.contains("Actual streamed content"))
            assertTrue(first.contains("stream1"))
            val stale = components("""[{"type":"card","content":[{"type":"text","content":"stale"}]}]""").single()
            registry.bind(context, listOf(stale.copy(children = visible)), 296, 640, theme)
            val second = registry.freeze(context).presentation.toString()
            assertTrue(second.contains("Actual streamed content"))
            assertFalse(second.contains("stale"))
        }

    @Test fun pixelBudgetEvictsOldSourcesAndOwnerClearClosesRemainingSources() =
        runTest {
            val registry = CanvasCaptureRegistry()
            bind(registry, """[{"type":"image","id":"one"},{"type":"image","id":"two"}]""")
            var closed = 0

            fun source() =
                object : CanvasPixels {
                    override suspend fun png() = "data:image/png;base64,cGl4ZWxz"

                    override fun retainedBytes() = 40L * 1024 * 1024

                    override fun close() {
                        closed++
                    }
                }
            registry.pixels("/components/0", source())
            registry.pixels("/components/1", source())
            assertEquals(1, closed)
            assertTrue(runCatching { registry.freeze(context) }.isFailure)
            registry.clear()
            assertEquals(2, closed)
        }

    @Test fun authorizedNewContextCannotCapturePreviousMountedOwnerChatOrRevision() =
        runTest {
            for (expected in listOf(context.copy(chatId = "other"), context.copy(epoch = 2), context.copy(revision = 3u), context.copy(owner = ConversationResumeStore.AccountIdentity("issuer", "other")))) {
                val registry = CanvasCaptureRegistry()
                bind(registry, """[{"type":"image","id":"visible"}]""")
                var requestedPixels = 0
                registry.pixels(
                    "/components/0",
                    CanvasPixels {
                        requestedPixels++
                        "data:image/png;base64,cGl4ZWxz"
                    },
                )
                assertTrue(runCatching { registry.freeze(expected) }.isFailure)
                assertEquals(0, requestedPixels)
            }
        }

    @Test fun hiddenSourceMetadataNeverLeavesCanvasButLiteralVisibleTextRemains() =
        runTest {
            val registry = CanvasCaptureRegistry()
            bind(registry, """[{"type":"text","content":"Visible _source_params text", "_source_agent":"hidden-agent", "_source_tool":"hidden-tool", "_source_params":{"query":"hidden-query","api_key":"hidden-key"},"extra":{"_source_params":{"secret":"nested-private"}}}]""")
            val output = registry.freeze(context).presentation.toString()
            assertTrue(output.contains("Visible _source_params text"))
            assertFalse(output.contains("hidden-"))
            assertFalse(output.contains("nested-private"))
        }

    @Test fun tooDeepTypedCanvasDoesNotThrowDuringBindingAndRefusesOnlyExport() =
        runTest {
            val registry = CanvasCaptureRegistry()
            var component = components("""[{"type":"text","content":"leaf"}]""").single()
            repeat(40) { component = Component("container", null, JsonObject(mapOf("type" to JsonPrimitive("container"))), listOf(component)) }
            registry.bind(context, listOf(component), 296, 640, theme)
            assertTrue(runCatching { registry.freeze(context) }.isFailure)
        }

    @Test fun childBearingNativeListExportsTheDisplayedChildren() =
        runTest {
            val registry = CanvasCaptureRegistry()
            val list = components("""[{"type":"list","content":[{"type":"text","content":"Child visible"}]}]""")
            registry.bind(context, list, 296, 640, theme)
            val output = registry.freeze(context).presentation.toString()
            assertTrue(output.contains("Child visible"))
            assertTrue(output.contains("\"type\":\"container\""))
        }

    @Test fun eachPrimitiveExportsOnlyItsActualDisplayedScalarFields() =
        runTest {
            val registry = CanvasCaptureRegistry()
            bind(
                registry,
                """[
          {"type":"text","content":"Visible","headers":{"Authorization":"PRIVATE"},"text":"PRIVATE-unused"},
          {"type":"code","content":"Visible code","code":"PRIVATE-unused","language":{"token":"PRIVATE"}},
          {"type":"alert","title":"Alert","message":"Message","variant":"PRIVATE-variant","items":["PRIVATE"]},
          {"type":"badge","label":"Badge","text":"PRIVATE-unused"},
          {"type":"hero","title":"Hero","badges":["Shown",{"private":"PRIVATE"},null],"variant":"PRIVATE"},
          {"type":"metric","title":"Metric","value":3,"subtitle":"Units","progress":0.5,"variant":"success","headers":{"token":"PRIVATE"}},
          {"type":"progress","label":"Progress","progress":50,"max":{"secret":"PRIVATE"}},
          {"type":"rating","value":2.7,"max":5,"label":"PRIVATE"},
          {"type":"divider","content":"PRIVATE"},
          {"type":"card","title":"Card","children":[],"subtitle":"PRIVATE"},
          {"type":"tabs","tabs":[{"label":{"secret":"PRIVATE"},"children":[],"hidden":"PRIVATE"}]}
        ]""",
            )
            val result = registry.freeze(context).presentation
            val output = result.toString()
            assertFalse(output.contains("PRIVATE"))
            assertTrue(output.contains("Visible code"))
            assertTrue(output.contains("Shown"))
            assertTrue(output.contains("Tab 1"))
            val actual = result["components"] as JsonArray
            assertEquals(JsonPrimitive(0.5), (actual[6] as JsonObject)["value"])
            assertEquals(JsonPrimitive(2), (actual[7] as JsonObject)["value"])
        }

    @Test fun nestedTableListKeyValueAndTimelineMetadataIsNotNativeDisplayContent() =
        runTest {
            val registry = CanvasCaptureRegistry()
            bind(
                registry,
                """[
          {"type":"table","headers":["Name",{"Authorization":"PRIVATE"},7],"rows":[["Visible {api_key: literal}",{"secret":"PRIVATE"},null,42],[true,["PRIVATE"]],{"secret":"PRIVATE"}],"total_rows":50,"page_size":10,"page_offset":0},
          {"type":"list","items":["Visible _source_params literal",{"text":"PRIVATE"},false,5,null]},
          {"type":"keyvalue","pairs":[{"key":"Shown key","label":"PRIVATE-unused","value":"Shown value","metadata":{"secret":"PRIVATE"}},{"label":"Fallback","value":{"secret":"PRIVATE"}},"PRIVATE"]},
          {"type":"timeline","items":[{"title":"Shown title","label":"PRIVATE-unused","description":"PRIVATE"},{"label":"Shown label","metadata":"PRIVATE"},{"text":"Shown text"},{"title":{"secret":"PRIVATE"},"label":"PRIVATE-unused"},"PRIVATE"]}
        ]""",
            )
            val actual = registry.freeze(context).presentation["components"] as JsonArray
            assertFalse(actual.toString().contains("PRIVATE"))
            assertEquals(Json.parseToJsonElement("""["Name","7"]"""), (actual[0] as JsonObject)["headers"])
            assertEquals(Json.parseToJsonElement("""[["Visible {api_key: literal}","","","42"],["true",""]]"""), (actual[0] as JsonObject)["rows"])
            assertEquals(Json.parseToJsonElement("""["Visible _source_params literal","false","5"]"""), (actual[1] as JsonObject)["items"])
            assertEquals(Json.parseToJsonElement("""[{"key":"Shown key","value":"Shown value"},{"key":"Fallback","value":""}]"""), (actual[2] as JsonObject)["items"])
            assertEquals(Json.parseToJsonElement("""[{"title":"Shown title"},{"title":"Shown label"},{"title":"Shown text"},{"title":""}]"""), (actual[3] as JsonObject)["items"])
        }

    @Test fun malformedComponentIdentityCannotTransmitNestedPrivateMetadata() =
        runTest {
            for (raw in listOf("""[{"type":"text","id":{"token":"PRIVATE"},"content":"Visible"}]""", """[{"type":"text","id":"first","component_id":"second","content":"Visible"}]""")) {
                val registry = CanvasCaptureRegistry()
                bind(registry, raw)
                val failure = runCatching { registry.freeze(context) }.exceptionOrNull()
                assertNotNull(failure)
                assertFalse(failure.toString().contains("PRIVATE"))
            }
        }

    @Test fun measuredImageBoxOverridesAuthoredDimensionsAndNeverBecomesVisibleCaption() =
        runTest {
            val registry = CanvasCaptureRegistry()
            bind(registry, """[{"type":"image","id":"image","width":9999,"height":8888,"alt":"Accessible image","caption":"PRIVATE-unused-caption"}]""")
            registry.pixels("/components/0", CanvasPixels { "data:image/png;base64,cGl4ZWxz" })
            assertTrue(runCatching { registry.freeze(context) }.isFailure)
            registry.imageSize("/components/0", 296.5, 148.25)
            val capture = registry.freeze(context)
            val image = (capture.presentation["components"] as JsonArray).single() as JsonObject
            assertEquals(JsonPrimitive(296.5), image["width"])
            assertEquals(JsonPrimitive(148.25), image["height"])
            assertEquals(JsonPrimitive("Accessible image"), image["alt"])
            assertFalse(image.toString().contains("PRIVATE"))
            for (size in listOf(0.0 to 1.0, -1.0 to 1.0, Double.NaN to 1.0, 1.0 to Double.POSITIVE_INFINITY, 16385.0 to 1.0)) {
                registry.imageSize("/components/0", size.first, size.second)
                assertTrue(runCatching { registry.freeze(context) }.isFailure)
            }
        }

    @Test fun frozenSnapshotSurvivesLocalResizeDisclosureAndUnmountButKeepsOwnerFences() =
        runTest {
            val registry = CanvasCaptureRegistry()
            val raw = """[{"type":"collapsible","content":[{"type":"text","content":"visible"}]}]"""
            bind(registry, raw)
            registry.expand("/components/0", true)
            val frozen = registry.freeze(context)
            val bytes = frozen.presentation.toString()
            registry.expand("/components/0", false)
            registry.bind(context, components(raw), 900, 600, theme)
            registry.unmount()
            assertFalse(registry.isCurrent(frozen, context))
            assertTrue(frozen.canDeliver(context))
            assertEquals(bytes, frozen.presentation.toString())
            for (current in listOf(null, context.copy(epoch = 2), context.copy(chatId = "other"), context.copy(revision = 3u), context.copy(operations = emptySet()), context.copy(owner = ConversationResumeStore.AccountIdentity("issuer", "other")))) {
                assertFalse(frozen.canDeliver(current))
            }
        }

    @Test fun resizingWhilePixelsArePendingStillRefusesTheUnfinishedCapture() =
        runTest {
            val registry = CanvasCaptureRegistry()
            val raw = """[{"type":"image","id":"image"}]"""
            bind(registry, raw)
            registry.imageSize("/components/0", 296.0, 100.0)
            val started = CompletableDeferred<Unit>()
            val finish = CompletableDeferred<String>()
            registry.pixels(
                "/components/0",
                CanvasPixels {
                    started.complete(Unit)
                    finish.await()
                },
            )
            val pending = async { runCatching { registry.freeze(context) } }
            started.await()
            registry.imageSize("/components/0", 280.0, 100.0)
            finish.complete("data:image/png;base64,cGl4ZWxz")
            assertTrue(pending.await().isFailure)
        }
}
