package com.personalailabs.astraldeep.app.rest

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import okhttp3.Authenticator
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardOpenOption
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.CoroutineContext

internal class WorkspaceRequestException(val userMessage: String) : IOException(userMessage)

internal class WorkspaceRest(
    private val baseUrl: String,
    client: OkHttpClient = OkHttpClient(),
    private val allowLocalHttp: Boolean = false,
    private val maxExportBytes: Long = 64L * 1024 * 1024,
) {
    private val client =
        client.newBuilder()
            .apply {
                interceptors().clear()
                networkInterceptors().clear()
            }
            .callTimeout(minOf(30_000, client.callTimeoutMillis.takeIf { it > 0 } ?: 30_000).toLong(), TimeUnit.MILLISECONDS)
            .retryOnConnectionFailure(false)
            .followRedirects(false)
            .followSslRedirects(false)
            .authenticator(Authenticator.NONE)
            .proxyAuthenticator(Authenticator.NONE)
            .cookieJar(CookieJar.NO_COOKIES)
            .cache(null)
            .addNetworkInterceptor { chain ->
                // OkHttp may follow a 503 Retry-After even with connection retries disabled.
                val attempted = chain.request().tag(AtomicBoolean::class.java)
                if (attempted == null || attempted.getAndSet(true)) throw IOException("Workspace request already attempted")
                chain.proceed(chain.request())
            }.build()

    suspend fun shareCanvas(
        token: String,
        chatId: String,
    ): String =
        safely(SHARE_FAILED) {
            validateChat(chatId)
            val url = serverOrigin().newBuilder().encodedPath("/api/share").build()
            val body =
                buildJsonObject {
                    put("chat_id", chatId)
                    put("scope", "canvas")
                }
            val request =
                authenticated(url, token)
                    .post(body.toString().toRequestBody("application/json; charset=utf-8".toMediaType()))
                    .build()
            execute(request) { response, context ->
                if (response.code == 403) {
                    val refusal = readShareJson(response, context)
                    if (refusal.string("error") == "phi_blocked") throw WorkspaceRequestException(PHI_REFUSED)
                }
                if (response.code != 201) throw WorkspaceRequestException(SHARE_FAILED)
                val result = readShareJson(response, context)
                val reference = result.string("share_url") ?: throw WorkspaceRequestException(SHARE_FAILED)
                shareUrl(reference).toString()
            }
        }

    /** The caller supplies a fresh path inside its private, owner-scoped staging directory. */
    suspend fun exportCanvas(
        token: String,
        chatId: String,
        revision: ULong,
        destination: File,
    ) {
        var complete = false
        try {
            safely(EXPORT_FAILED) {
                validateChat(chatId)
                require(maxExportBytes > 0)
                serverOrigin()
                val url = artifactDownloadUrl(baseUrl, "/api/export/canvas/$chatId.html?render_revision=$revision", allowLocalHttp)
                execute(authenticated(url, token).get().build()) { response, context ->
                    if (response.code == 409) throw WorkspaceRequestException(REVISION_CHANGED)
                    if (response.code != 200) throw WorkspaceRequestException(EXPORT_FAILED)
                    if (response.headers.values("X-Astral-Render-Revision") != listOf(revision.toString())) {
                        throw WorkspaceRequestException(REVISION_CHANGED)
                    }
                    context.ensureActive()
                    Files.newOutputStream(
                        destination.toPath(),
                        StandardOpenOption.CREATE,
                        StandardOpenOption.WRITE,
                        StandardOpenOption.TRUNCATE_EXISTING,
                        LinkOption.NOFOLLOW_LINKS,
                    ).use { copyBounded(response, it, maxExportBytes, context) }
                }
            }
            currentCoroutineContext().ensureActive()
            complete = true
        } finally {
            if (!complete) destination.delete()
        }
    }

    /** Existing owner/revision authorization runs before the native visible-state freeze. */
    suspend fun authorizeCanvas(
        token: String,
        chatId: String,
        revision: ULong,
    ) = safely(EXPORT_FAILED) {
        validateChat(chatId)
        require(revision <= Long.MAX_VALUE.toULong())
        val url = artifactDownloadUrl(baseUrl, "/api/export/canvas/$chatId.html?render_revision=$revision", allowLocalHttp)
        execute(authenticated(url, token).get().build()) { response, context ->
            checkExportRevision(response, revision)
            copyBounded(
                response,
                object : OutputStream() {
                    override fun write(value: Int) = Unit

                    override fun write(
                        bytes: ByteArray,
                        offset: Int,
                        length: Int,
                    ) = Unit
                },
                maxExportBytes,
                context,
            )
        }
    }

    /** Client display bytes remain ephemeral and the pure renderer grants no additional authority. */
    suspend fun canvasPresentation(
        token: String,
        chatId: String,
        revision: ULong,
        capture: JsonObject,
    ): JsonObject =
        safely(EXPORT_FAILED) {
            validateChat(chatId)
            require(revision <= Long.MAX_VALUE.toULong())
            val bytes = capture.toString().toByteArray(Charsets.UTF_8)
            require(bytes.size <= 8 * 1024 * 1024)
            val url = artifactDownloadUrl(baseUrl, "/api/export/canvas/$chatId/presentation?render_revision=$revision", allowLocalHttp)
            execute(
                authenticated(url, token).post(bytes.toRequestBody("application/json; charset=utf-8".toMediaType())).build(),
            ) { response, context ->
                checkExportRevision(response, revision)
                require(response.body?.contentType()?.let { it.type == "application" && it.subtype == "json" } == true)
                val data = ByteArrayOutputStream().also { copyBounded(response, it, 32L * 1024 * 1024, context) }.toByteArray()
                val text =
                    Charsets.UTF_8.newDecoder().onMalformedInput(
                        CodingErrorAction.REPORT,
                    ).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(data)).toString()
                requireDistinctKeys(text)
                val result = JSON.parseToJsonElement(text) as? JsonObject ?: throw WorkspaceRequestException(EXPORT_FAILED)
                require(result.keys == setOf("version", "html", "viewport", "theme"))
                require(result.string("version") == "astral.canvas-export/v1" && result.string("html") != null)
                require(result["viewport"] == capture["viewport"] && result["theme"] == capture["theme"])
                result
            }
        }

    private fun checkExportRevision(
        response: Response,
        revision: ULong,
    ) {
        if (response.code == 409) throw WorkspaceRequestException(REVISION_CHANGED)
        if (response.code != 200) throw WorkspaceRequestException(EXPORT_FAILED)
        if (response.headers.values("X-Astral-Render-Revision") != listOf(revision.toString())) {
            throw WorkspaceRequestException(
                REVISION_CHANGED,
            )
        }
    }

    private fun serverOrigin(): HttpUrl {
        require(baseUrl == baseUrl.trim() && baseUrl.none { it.isISOControl() || it == '\\' })
        val raw = URI(baseUrl)
        require(raw.rawUserInfo == null && raw.rawFragment == null && raw.rawQuery == null)
        return artifactDownloadUrl(baseUrl, "/api/export/workspace", allowLocalHttp)
            .newBuilder().encodedPath("/").build()
    }

    private fun shareUrl(reference: String): HttpUrl {
        val origin = serverOrigin()
        require(reference == reference.trim() && reference.none { it.isISOControl() || it == '\\' })
        val raw = URI(reference)
        require(raw.rawUserInfo == null && raw.rawQuery == null && raw.rawFragment == null)
        require(raw.isAbsolute || (reference.startsWith('/') && !reference.startsWith("//")))
        require(SHARE_PATH.matches(raw.rawPath.orEmpty()))
        val url = requireNotNull(origin.resolve(reference))
        require(url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port)
        require(url.username.isEmpty() && url.password.isEmpty())
        return url
    }

    private fun authenticated(
        url: HttpUrl,
        token: String,
    ): Request.Builder {
        require(token.isNotBlank() && token.length <= 16384 && token.none(Char::isISOControl))
        return Request.Builder().url(url)
            .header("Authorization", "Bearer $token")
            .header("Cache-Control", "no-store")
            .tag(AtomicBoolean::class.java, AtomicBoolean())
    }

    private fun validateChat(chatId: String) {
        require(CHAT_ID.matches(chatId))
    }

    private suspend fun <T> execute(
        request: Request,
        consume: (Response, CoroutineContext) -> T,
    ): T =
        coroutineScope {
            val call = client.newCall(request)
            // This child interrupts blocked headers/body reads immediately; the IO child
            // still finishes closing its handles before this structured scope returns.
            val cancellation =
                launch(Dispatchers.Unconfined, start = CoroutineStart.UNDISPATCHED) {
                    try {
                        awaitCancellation()
                    } finally {
                        call.cancel()
                    }
                }
            try {
                withContext(Dispatchers.IO) {
                    val context = currentCoroutineContext()
                    context.ensureActive()
                    call.execute().use { response ->
                        context.ensureActive()
                        consume(response, context)
                    }
                }
            } finally {
                cancellation.cancel()
            }
        }

    private fun copyBounded(
        response: Response,
        destination: OutputStream,
        limit: Long,
        context: CoroutineContext,
    ) {
        val body = response.body ?: throw IOException("Workspace response has no body")
        if (body.contentLength() > limit) throw IOException("Workspace response exceeds limit")
        body.byteStream().use { input ->
            val buffer = ByteArray(8192)
            var total = 0L
            while (true) {
                context.ensureActive()
                val count = input.read(buffer)
                if (count == -1) break
                context.ensureActive()
                total += count
                if (total > limit) throw IOException("Workspace response exceeds limit")
                destination.write(buffer, 0, count)
            }
        }
    }

    private fun readShareJson(
        response: Response,
        context: CoroutineContext,
    ): JsonObject {
        val bytes = ByteArrayOutputStream().also { copyBounded(response, it, 65536, context) }.toByteArray()
        val text =
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
        val result = JSON.parseToJsonElement(text) as? JsonObject ?: throw WorkspaceRequestException(SHARE_FAILED)
        requireDistinctKeys(text)
        return result
    }

    /** kotlinx.serialization otherwise silently keeps the last duplicate object key. */
    private fun requireDistinctKeys(text: String) {
        val keys = mutableSetOf<String>()
        var depth = 0
        var index = 0
        while (index < text.length) {
            when (text[index]) {
                '{', '[' -> depth++
                '}', ']' -> depth--
                '"' -> {
                    val start = index++
                    while (index < text.length && text[index] != '"') {
                        if (text[index] == '\\') index++
                        index++
                    }
                    val end = ++index
                    while (index < text.length && text[index].isWhitespace()) index++
                    if (depth == 1 && text.getOrNull(index) == ':') {
                        require(keys.add(JSON.decodeFromString<String>(text.substring(start, end))))
                    }
                    continue
                }
            }
            index++
        }
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private suspend fun <T> safely(
        message: String,
        operation: suspend () -> T,
    ): T =
        try {
            currentCoroutineContext().ensureActive()
            operation()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            currentCoroutineContext().ensureActive()
            // Platform/network/JSON errors can contain URLs and raw response text.
            throw (failure as? WorkspaceRequestException ?: WorkspaceRequestException(message))
        }

    private companion object {
        val JSON = Json { isLenient = false }
        val SHARE_PATH = Regex("/share/[A-Za-z0-9_-]{32,256}")
        val CHAT_ID = Regex("[A-Za-z0-9_-]{1,128}")
        const val SHARE_FAILED = "Couldn't create the share link."
        const val PHI_REFUSED = "Sharing refused: the content matched the PHI gate."
        const val EXPORT_FAILED = "Couldn't export this canvas. Try again."
        const val REVISION_CHANGED = "Canvas changed. Reload the chat before exporting."
    }
}
