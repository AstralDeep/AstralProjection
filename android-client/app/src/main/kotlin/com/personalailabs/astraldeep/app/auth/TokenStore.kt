// AndroidX encrypted persistence for AppAuth grants, exact-server session cookies, and scoped mesh seeds.
// Implements ServerSessionPersistence and MeshKeyStorage for the native authentication and enrollment controllers.

package com.personalailabs.astraldeep.app.auth

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.personalailabs.astraldeep.app.push.PushCustodyStorage
import net.openid.appauth.AuthState
import java.security.MessageDigest
import java.time.Instant

class TokenStore(context: Context, file: String = FILE) : ServerSessionPersistence, MeshKeyStorage, PushCustodyStorage {
    private val prefs =
        EncryptedSharedPreferences.create(
            context,
            file,
            MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )

    override fun loadPushCustody(): String? = runCatching { prefs.getString("push.owner_binding.v1", null) }.getOrNull()

    override fun savePushCustody(value: String): Boolean =
        runCatching {
            prefs.edit().putString("push.owner_binding.v1", value).commit()
        }.getOrDefault(false)

    override fun clearPushCustody(): Boolean = runCatching { prefs.edit().remove("push.owner_binding.v1").commit() }.getOrDefault(false)

    fun load(): AuthState? = prefs.getString(KEY, null)?.let { runCatching { AuthState.jsonDeserialize(it) }.getOrNull() }

    fun save(state: AuthState) {
        prefs.edit().putString(KEY, state.jsonSerializeString()).apply()
    }

    fun clear() {
        prefs.edit().remove(KEY).apply()
    }

    override fun loadMesh(key: String): String? = prefs.getString("mesh.$key", null)

    override fun saveMesh(
        key: String,
        value: String,
    ): Boolean = prefs.edit().putString("mesh.$key", value).commit()

    override fun removeMesh(key: String): Boolean = prefs.edit().remove("mesh.$key").commit()

    override fun retainOnlyMesh(key: String?): Boolean =
        prefs.edit().apply {
            prefs.all.keys.filter { it.startsWith("mesh.") && it != "mesh.$key" }.forEach(::remove)
        }.commit()

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
            remove(KEY)
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
