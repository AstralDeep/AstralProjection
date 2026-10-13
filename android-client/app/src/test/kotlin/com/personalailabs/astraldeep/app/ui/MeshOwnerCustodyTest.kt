// Verifies authenticated app owner binding preserves restart keys and retires foreign server/account custody.
package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.auth.ConversationResumeStore.AccountIdentity
import com.personalailabs.astraldeep.app.auth.MeshEnrollmentCustody
import com.personalailabs.astraldeep.app.auth.MeshEnrollmentScope
import com.personalailabs.astraldeep.app.auth.MeshKeyStorage
import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.core.protocol.DeviceCapabilities
import com.personalailabs.astraldeep.core.protocol.Inbound
import com.personalailabs.astraldeep.core.sdui.Component
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

@OptIn(ExperimentalCoroutinesApi::class)
class MeshOwnerCustodyTest {
    private fun token(owner: String): String {
        val body = "{\"iss\":\"https://iam.test/realms/astral\",\"sub\":\"$owner\"}"
        return "e30." + Base64.getUrlEncoder().withoutPadding().encodeToString(body.toByteArray()) + ".c2ln"
    }

    private fun model(
        store: Store,
        server: String = "https://server.test",
    ): AppViewModel =
        AppViewModel(
            OrchestratorClient("ws://localhost:9/ws"),
            AstralRest("http://localhost:9"),
            meshStorage = store,
            meshServerBase = server,
        )

    @Test
    fun owner_restart_preserves_key_and_actual_account_or_server_change_retires_it() {
        Dispatchers.setMain(StandardTestDispatcher())
        try {
            val scope = MeshEnrollmentScope("https://server.test", "https://iam.test/realms/astral", "owner")
            val store = Store()
            val custody = MeshEnrollmentCustody(scope, store)
            val identity = custody.publicIdentity { true }
            val first = model(store)
            first.start(token("owner"), DeviceCapabilities(400, 800))
            assertNotNull(store.loadMesh(scope.storageKey))
            assertEquals(identity, custody.publicIdentity { true })
            val restarted = model(store)
            restarted.start(token("owner"), DeviceCapabilities(400, 800))
            assertEquals(identity, custody.publicIdentity { true })
            restarted.start(token("other"), DeviceCapabilities(400, 800))
            assertNull(store.loadMesh(scope.storageKey))
            custody.publicIdentity { true }
            val foreign = model(store, "https://foreign.test")
            foreign.start(token("owner"), DeviceCapabilities(400, 800))
            assertNull(store.loadMesh(scope.storageKey))
            first.signOut {}
            restarted.signOut {}
            foreign.signOut {}
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun failed_local_mesh_actions_publish_terminal_outcomes_to_the_actual_form_caller() {
        val dispatcher = StandardTestDispatcher()
        Dispatchers.setMain(dispatcher)
        try {
            for (failure in listOf("link", "storage", "server")) {
                val store = Store()
                val server = if (failure == "server") "http://server.test" else "https://server.test"
                val vm = model(store, server)
                val action = if (failure == "storage") "chrome_mesh_create" else "chrome_mesh_redeem"
                AppViewModel::class.java.getDeclaredField("account").apply { isAccessible = true }
                    .set(vm, AccountIdentity("https://iam.test/realms/astral", "owner"))
                AppViewModel::class.java.getDeclaredField("token").apply { isAccessible = true }.set(vm, token("owner"))
                @Suppress("UNCHECKED_CAST")
                val state =
                    AppViewModel::class.java.getDeclaredField("_state").apply { isAccessible = true }
                        .get(vm) as MutableStateFlow<UiState>
                state.value =
                    UiState(
                        connection = ConnectionState.Connected,
                        connectionGeneration = "11111111-1111-4111-8111-111111111111",
                        screen = Screen.Surface,
                        pendingSurfaceKey = "mesh",
                        pendingSurface =
                            Inbound.ChromeSurface(
                                "mesh", "Mesh devices",
                                listOf(
                                    Component(
                                        "param_picker", id = null, children = emptyList(), attributes = buildJsonObject { put("submit_action", action) },
                                    ),
                                ),
                            ),
                    )
                if (failure == "link") {
                    MeshEnrollmentCustody(
                        MeshEnrollmentScope(server, "https://iam.test/realms/astral", "owner"),
                        store,
                    ).publicIdentity { true }
                }
                store.failSave = failure == "storage"
                vm.sendEvent(
                    action,
                    buildJsonObject {
                        putJsonObject("fields") {
                            if (failure == "storage") {
                                put("label", "Task device")
                                put("device_key", "")
                                put("scopes", "tools:read")
                                put("ttl_seconds", "3600")
                            } else {
                                put("link", "https://foreign.test/enroll#invalid")
                            }
                        }
                    },
                )
                dispatcher.scheduler.runCurrent()
                assertEquals(1L, state.value.surfaceOutcomeRevision, failure)
                assertNotNull(state.value.surfaceErrorMessage, failure)
                assertEquals(Screen.Surface, state.value.screen, failure)
                assertEquals("mesh", state.value.pendingSurfaceKey, failure)
            }
        } finally {
            Dispatchers.resetMain()
        }
    }

    private class Store : MeshKeyStorage {
        var failSave = false
        private val values = mutableMapOf<String, String>()

        override fun loadMesh(key: String): String? = values[key]

        override fun saveMesh(
            key: String,
            value: String,
        ): Boolean {
            if (failSave) return false
            values[key] = value
            return true
        }

        override fun removeMesh(key: String): Boolean {
            values.remove(key)
            return true
        }

        override fun retainOnlyMesh(key: String?): Boolean {
            values.keys.filter { it != key }.forEach(values::remove)
            return true
        }
    }
}
