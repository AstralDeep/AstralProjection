package com.personalailabs.astraldeep.app.rest

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.io.OutputStream
import java.net.URI
import java.net.URLDecoder

internal fun artifactDownloadUrl(
    baseUrl: String,
    reference: String,
    allowLocalHttp: Boolean = false,
): HttpUrl {
    require(reference.none { it.isISOControl() || it == '\\' }) { "Invalid download URL" }
    val raw = URI(reference)
    require(raw.rawUserInfo == null && raw.rawFragment == null) { "Invalid download URL" }
    require(raw.isAbsolute || (reference.startsWith('/') && !reference.startsWith("//"))) { "Invalid download URL" }
    raw.rawPath.orEmpty().split('/').forEach { part ->
        var decoded = part
        repeat(3) {
            decoded = URLDecoder.decode(decoded.replace("+", "%2B"), "UTF-8")
            require(decoded !in setOf(".", "..") && '/' !in decoded && '\\' !in decoded && decoded.none(Char::isISOControl)) {
                "Invalid download path"
            }
        }
    }
    val base = requireNotNull(baseUrl.toHttpUrlOrNull()) { "Invalid server URL" }
    val url = requireNotNull(base.resolve(reference)) { "Invalid download URL" }
    require(base.username.isEmpty() && base.password.isEmpty() && base.fragment == null) { "Invalid server URL" }
    require(url.username.isEmpty() && url.password.isEmpty() && url.fragment == null) { "Invalid download URL" }
    require(url.scheme == base.scheme && url.host == base.host && url.port == base.port) { "Download must use this server" }
    require(url.isHttps || (allowLocalHttp && url.host in setOf("localhost", "127.0.0.1", "::1", "10.0.2.2"))) {
        "Downloads require HTTPS"
    }
    require(url.encodedPath.startsWith("/api/download/") || url.encodedPath.startsWith("/api/export/")) {
        "Unsupported download endpoint"
    }
    return url
}

/** Public HTTPS files open in the system browser without app credentials or headers. */
internal fun publicDownloadBrowserUrl(
    baseUrl: String,
    reference: String,
): HttpUrl? {
    if (!reference.contains("://")) return null
    require(reference.none { it.isISOControl() || it == '\\' }) { "Invalid download URL" }
    val raw = URI(reference)
    require(raw.isAbsolute && raw.host != null && raw.rawUserInfo == null && raw.rawFragment == null) { "Invalid public URL" }
    val url = requireNotNull(reference.toHttpUrlOrNull()) { "Invalid public URL" }
    val base = requireNotNull(baseUrl.toHttpUrlOrNull()) { "Invalid server URL" }
    if (url.scheme == base.scheme && url.host == base.host && url.port == base.port) return null
    require(url.isHttps && url.username.isEmpty() && url.password.isEmpty()) { "Public downloads require HTTPS" }
    return url
}

internal fun safeDownloadFilename(value: String): String =
    value.replace(Regex("[\\\\/\\p{C}]"), "_").take(120).trim(' ', '.').ifBlank { "download" }

/** Redirects are refused before any new request can receive the owner's token. */
internal class ArtifactDownload(
    private val baseUrl: String,
    client: OkHttpClient = OkHttpClient(),
    private val allowLocalHttp: Boolean = false,
    private val maxBytes: Long = 64L * 1024 * 1024,
) {
    private val client = client.newBuilder().followRedirects(false).followSslRedirects(false).build()

    fun copyTo(
        reference: String,
        token: String,
        destination: OutputStream,
    ) {
        require(token.isNotBlank()) { "Sign in to download this file" }
        val url = artifactDownloadUrl(baseUrl, reference, allowLocalHttp)
        val request = Request.Builder().url(url).header("Authorization", "Bearer $token").build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("Download failed (${response.code})")
            val body = response.body ?: throw IOException("Download returned no file")
            if (body.contentLength() > maxBytes) throw IOException("Download exceeds the 64 MB limit")
            body.byteStream().use { input ->
                val buffer = ByteArray(8192)
                var total = 0L
                while (true) {
                    val count = input.read(buffer)
                    if (count == -1) break
                    total += count
                    if (total > maxBytes) throw IOException("Download exceeds the 64 MB limit")
                    destination.write(buffer, 0, count)
                }
            }
        }
    }
}
