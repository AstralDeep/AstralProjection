// One backend/account session custody owner: epoch fencing under a shared monitor ensures a stale response
// can never publish after sign-out or a new interactive attempt. Used by MainActivity and OrchestratorClient.

package com.personalailabs.astraldeep.app.auth

import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.time.Instant

internal interface ServerSessionPersistence {
    fun loadSession(
        scope: ServerSessionScope,
        now: Instant,
    ): ServerSession?

    fun saveSession(session: ServerSession): Boolean

    fun clearSession(scope: ServerSessionScope): Boolean
}

class ServerSessionCoordinator internal constructor(
    private val transport: ServerSessionTransport,
    private val persistence: ServerSessionPersistence,
    private val clock: () -> Instant = { Instant.now() },
) {
    private val gate = Any()
    private val refreshLock = Mutex()
    private var epoch = 0L
    private var session: ServerSession? = null
    private var pending: Attempt? = null

    class Attempt internal constructor(internal val epoch: Long) {
        internal var consumed = false

        override fun toString(): String = "ServerSessionAttempt"
    }

    fun begin(): Attempt =
        synchronized(gate) {
            epoch++
            session = null
            pending = null
            if (!persistence.clearSession(transport.scope)) throw ServerSessionException(ServerSessionException.Reason.STORAGE)
            Attempt(epoch).also { pending = it }
        }

    suspend fun exchange(
        attempt: Attempt,
        code: ServerAuthorizationCode,
    ): String {
        synchronized(gate) {
            if (pending !== attempt || epoch != attempt.epoch || attempt.consumed) retired()
            attempt.consumed = true
        }
        val result = transport.exchange(code)
        val job = currentCoroutineContext()[Job]
        job?.ensureActive()
        return synchronized(gate) {
            if (pending !== attempt || epoch != attempt.epoch) retired()
            persist(result, job)
            pending = null
            result.accessToken
        }
    }

    fun restore(): Boolean =
        synchronized(gate) {
            if (session != null || pending != null) return@synchronized session != null
            val restored = persistence.loadSession(transport.scope, clock()) ?: return@synchronized false
            if (!restored.scope.matches(transport.scope)) sessionInvalid()
            epoch++
            session = restored
            true
        }

    suspend fun refresh(): String {
        val original = synchronized(gate) { (session ?: retired()) to epoch }
        return refreshLock.withLock {
            val current =
                synchronized(gate) {
                    if (epoch != original.second) retired()
                    session ?: retired()
                }
            if (current !== original.first) return@withLock current.accessToken
            val result = transport.refresh(current)
            val job = currentCoroutineContext()[Job]
            job?.ensureActive()
            synchronized(gate) {
                if (epoch != original.second || session !== current) retired()
                persist(result, job)
                result.accessToken
            }
        }
    }

    fun retire(): ServerSession? =
        synchronized(gate) {
            epoch++
            pending = null
            val old = session
            session = null
            if (!persistence.clearSession(transport.scope)) throw ServerSessionException(ServerSessionException.Reason.STORAGE)
            old
        }

    suspend fun logout(retired: ServerSession): Boolean = transport.logout(retired)

    internal fun <T> withToken(
        token: String,
        block: () -> T,
    ): T =
        synchronized(gate) {
            val current = session ?: retired()
            if (current.accessToken != token || !current.cookieExpiresAt.isAfter(clock())) retired()
            block()
        }

    class SocketTicket internal constructor(internal val session: ServerSession, internal val epoch: Long) {
        internal val cookie: String get() = session.cookie

        override fun toString(): String = "ServerSessionSocketTicket(private)"
    }

    fun socketTicket(
        url: String,
        token: String,
    ): SocketTicket =
        synchronized(gate) {
            val parsed = url.replaceFirst("wss://", "https://").toHttpUrlOrNull() ?: sessionInvalid()
            val origin = transport.scope.origin
            if (!url.startsWith("wss://") || parsed.scheme != origin.scheme || parsed.host != origin.host ||
                parsed.port != origin.port || parsed.encodedPath != "/ws" || parsed.query != null ||
                parsed.fragment != null || parsed.username.isNotEmpty() || parsed.password.isNotEmpty()
            ) {
                sessionInvalid()
            }
            val current = session ?: retired()
            if (current.accessToken != token || !current.cookieExpiresAt.isAfter(clock())) retired()
            SocketTicket(current, epoch)
        }

    fun isCurrent(ticket: SocketTicket): Boolean =
        synchronized(gate) {
            epoch == ticket.epoch && session === ticket.session && ticket.session.cookieExpiresAt.isAfter(clock())
        }

    // No sign-out/write may land between this check and socket creation
    internal fun <T> withCurrent(
        ticket: SocketTicket,
        block: () -> T,
    ): T =
        synchronized(gate) {
            if (!isCurrent(ticket)) retired()
            block()
        }

    private fun persist(
        value: ServerSession,
        job: Job?,
    ) {
        job?.ensureActive()
        if (!persistence.saveSession(value)) throw ServerSessionException(ServerSessionException.Reason.STORAGE)
        if (job?.isActive == false) {
            epoch++
            pending = null
            session = null
            persistence.clearSession(transport.scope)
            job.ensureActive()
        }
        session = value
    }

    private fun retired(): Nothing = throw ServerSessionException(ServerSessionException.Reason.RETIRED)
}
