// Verifies Android opens only the not available yet screen and carries no sign-in code or stored-token access.
// Source guards read the main tree so a returning import or token key name fails here.
package com.personalailabs.astraldeep.app

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NotAvailableYetTest {
    private val main = File("src/main/kotlin")

    private fun sources(): List<Pair<String, String>> =
        main.walkTopDown().filter { it.isFile && it.extension == "kt" }.map { it.path to it.readText() }.toList()

    @Test
    fun the_screen_text_is_the_agreed_one_line() {
        assertEquals("Astral for Android is not available yet. Use the Mac or iPhone app.", NotAvailableYet.TEXT)
    }

    @Test
    fun main_activity_hosts_the_screen_and_nothing_else() {
        val activity = File(main, "com/personalailabs/astraldeep/app/MainActivity.kt").readText()
        assertTrue("NotAvailableYetScreen()" in activity)
        assertEquals(1, Regex("setContent \\{").findAll(activity).count())
        for (forbidden in listOf("OrchestratorClient", "AppViewModel", "RootScaffold", "AstralRest", "Intent(")) {
            assertFalse(forbidden in activity, "MainActivity must not reference $forbidden")
        }
    }

    @Test
    fun no_source_imports_app_auth_or_names_the_stored_token_files_or_keys() {
        val forbidden =
            listOf(
                "net.openid.appauth", "OidcAuth", "ServerSession", "KeycloakLogout", "TokenStore", "AuthState",
                "EncryptedSharedPreferences", "oauth2redirect", "push.owner_binding",
            )
        for ((path, text) in sources()) {
            for (word in forbidden) assertFalse(word in text, "$path names $word")
        }
    }
}
