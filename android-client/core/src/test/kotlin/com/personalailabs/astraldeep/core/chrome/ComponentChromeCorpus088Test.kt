package com.personalailabs.astraldeep.core.chrome

import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import java.security.MessageDigest
import kotlin.test.Test
import kotlin.test.assertEquals

class ComponentChromeCorpus088Test {
    @Test fun shared_server_corpus_has_the_same_native_dispositions_and_version_rows() {
        val file = File(System.getenv("ASTRAL_COMPONENT_CHROME_FIXTURE") ?: "../../contracts/fixtures/workspace_088/component_chrome.json")
        val bytes = file.readBytes()
        assertEquals("0fad08ce1881c4f6fe1d87aa684765e7f2e2764fb4da6b09bafd777eecb6a73d", MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
        val corpus = Json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
        corpus.getValue("actions").jsonArray.forEach { entry ->
            val row = entry.jsonObject
            val component =
                Component.fromJson(
                    buildJsonObject {
                        put("type", "table")
                        put("component_chrome", row.getValue("metadata"))
                    },
                )
            assertEquals(row.getValue("expected_kinds").jsonArray.map { it.jsonPrimitive.content }, ComponentChrome.actions(component).map { it.kind }, row.getValue("name").toString())
        }
        corpus.getValue("versions").jsonArray.forEach { entry ->
            val row = entry.jsonObject
            val component =
                Component.fromJson(
                    buildJsonObject {
                        put("type", "table")
                        put("versions", row.getValue("versions"))
                    },
                )
            val actual =
                JsonArray(
                    ComponentChrome.versions(component).map { version ->
                        buildJsonObject {
                            put("version_no", version.versionNo)
                            put("reason", version.reason)
                            put("created_at", version.createdAt)
                            put("title", version.title)
                        }
                    },
                )
            assertEquals(row.getValue("expected"), actual, row.getValue("name").toString())
        }
    }
}
