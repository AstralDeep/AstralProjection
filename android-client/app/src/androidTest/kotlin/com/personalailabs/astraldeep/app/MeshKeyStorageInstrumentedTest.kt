// Verifies actual Android protected mesh seed custody across process-owner reconstruction.
// A unique encrypted preferences namespace keeps acceptance data separate from owner sessions.
package com.personalailabs.astraldeep.app

import androidx.test.platform.app.InstrumentationRegistry
import com.personalailabs.astraldeep.app.auth.MeshEnrollmentCustody
import com.personalailabs.astraldeep.app.auth.MeshEnrollmentScope
import com.personalailabs.astraldeep.app.auth.TokenStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class MeshKeyStorageInstrumentedTest {
    @Test
    fun encrypted_seed_survives_restart_and_explicit_scope_retirement() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = "astral_mesh_test_" + UUID.randomUUID().toString()
        val scope = MeshEnrollmentScope("https://server.test", "https://iam.test/realms/astral", "synthetic-owner")
        try {
            val store = TokenStore(context, file)
            val first = MeshEnrollmentCustody(scope, store).publicIdentity { true }
            val encrypted = context.getSharedPreferences(file, 0).all.values.joinToString()
            assertFalse(encrypted.contains("seed"))
            assertFalse(encrypted.contains("member_id"))
            assertFalse(encrypted.contains(first.toString()))
            val restarted = TokenStore(context, file)
            assertEquals(first, MeshEnrollmentCustody(scope, restarted).publicIdentity { true })
            val other = MeshEnrollmentScope("https://other.test", scope.issuer, scope.owner)
            MeshEnrollmentCustody(other, restarted).publicIdentity { true }
            assertNull(restarted.loadMesh(scope.storageKey))
            assertTrue(restarted.retainOnlyMesh(null))
            assertNull(restarted.loadMesh(other.storageKey))
        } finally {
            context.deleteSharedPreferences(file)
        }
    }
}
