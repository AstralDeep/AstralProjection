package com.personalailabs.astraldeep.app.auth

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import net.openid.appauth.AuthState
import java.security.MessageDigest
import java.time.Instant

/**
 * Encrypted persistence for the AppAuth [AuthState] (access + refresh tokens),
 * backed by AndroidX Security `EncryptedSharedPreferences`. Only the refresh
 * token needs to survive process death; the access token is short-lived.
 */
class TokenStore(context: Context) : ServerSessionPersistence {
    private val prefs =
        EncryptedSharedPreferences.create(
            context,
            FILE,
            MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )

    fun load(): AuthState? = prefs.getString(KEY, null)?.let { runCatching { AuthState.jsonDeserialize(it) }.getOrNull() }

    fun save(state: AuthState) {
        prefs.edit().putString(KEY, state.jsonSerializeString()).apply()
    }

    fun clear() {
        prefs.edit().remove(KEY).apply()
    }

    override fun loadSession(
        scope: ServerSessionScope,
        now: Instant,
    ): ServerSession? {
        val pointer = custodyKey(scope)
        val key = prefs.getString(pointer, null) ?: return null
        if (!key.startsWith("$pointer.")) return null
        val raw = prefs.getString(key, null) ?: return null
        return try {
            ServerSession.decode(raw, scope, now).takeIf { key == "$pointer.${digest(it.userId)}" }
        } catch (_: Exception) {
            null
        }
    }

    override fun saveSession(session: ServerSession): Boolean {
        val pointer = custodyKey(session.scope)
        val key = "$pointer.${digest(session.userId)}"
        val old = prefs.getString(pointer, null)
        return prefs.edit().apply {
            if (old != null && old.startsWith("$pointer.") && old != key) remove(old)
            putString(key, session.encoded())
            putString(pointer, key)
            remove(KEY) // A successful fresh issuance has exactly one local refresh owner.
        }.commit()
    }

    override fun clearSession(scope: ServerSessionScope): Boolean {
        val pointer = custodyKey(scope)
        val old = prefs.getString(pointer, null)
        return prefs.edit().apply {
            if (old != null && old.startsWith("$pointer.")) remove(old)
            remove(pointer)
        }.commit()
    }

    private fun custodyKey(scope: ServerSessionScope): String {
        val identity = listOf(scope.origin.toString(), scope.issuer, scope.clientId, scope.redirectUri).joinToString("\u0000")
        return "server_session_v1." + digest(identity)
    }

    private fun digest(value: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value.encodeToByteArray()).joinToString("") { "%02x".format(it) }

    private companion object {
        const val FILE = "astral_auth"
        const val KEY = "auth_state"
    }
}
