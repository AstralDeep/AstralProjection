// Verifies authenticated app owner binding preserves restart keys and retires foreign server/account custody.
package com.personalailabs.astraldeep.app.ui

import com.personalailabs.astraldeep.app.auth.MeshEnrollmentCustody
import com.personalailabs.astraldeep.app.auth.MeshEnrollmentScope
import com.personalailabs.astraldeep.app.auth.MeshKeyStorage
import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.core.protocol.DeviceCapabilities
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
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

    private class Store : MeshKeyStorage {
        private val values = mutableMapOf<String, String>()

        override fun loadMesh(key: String): String? = values[key]

        override fun saveMesh(
            key: String,
            value: String,
        ): Boolean {
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
