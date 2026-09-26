// The sign-in Activity and root Compose host: resumes cached sessions via AuthAttemptFence, silently
// refreshes tokens through OidcAuth/ServerSession, and hosts AdaptiveShell once connected.

package com.personalailabs.astraldeep.app

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.personalailabs.astraldeep.app.auth.AuthAttemptFence
import com.personalailabs.astraldeep.app.auth.ConversationResumeStore
import com.personalailabs.astraldeep.app.auth.ConversationResumeStore.ClearReason
import com.personalailabs.astraldeep.app.auth.KeycloakLogout
import com.personalailabs.astraldeep.app.auth.OidcAuth
import com.personalailabs.astraldeep.app.auth.ServerSessionCoordinator
import com.personalailabs.astraldeep.app.auth.ServerSessionException
import com.personalailabs.astraldeep.app.auth.ServerSessionScope
import com.personalailabs.astraldeep.app.auth.ServerSessionTransport
import com.personalailabs.astraldeep.app.auth.TokenStore
import com.personalailabs.astraldeep.app.auth.keycloakEndpoints
import com.personalailabs.astraldeep.app.auth.routeAfterRefresh
import com.personalailabs.astraldeep.app.render.CanvasCaptureRegistry
import com.personalailabs.astraldeep.app.render.Download
import com.personalailabs.astraldeep.app.render.Emit
import com.personalailabs.astraldeep.app.render.Renderer
import com.personalailabs.astraldeep.app.render.ThemeSink
import com.personalailabs.astraldeep.app.render.renderers.registerAllRenderers
import com.personalailabs.astraldeep.app.rest.ArtifactDownload
import com.personalailabs.astraldeep.app.rest.AstralRest
import com.personalailabs.astraldeep.app.rest.artifactDownloadUrl
import com.personalailabs.astraldeep.app.rest.publicDownloadBrowserUrl
import com.personalailabs.astraldeep.app.rest.safeDownloadFilename
import com.personalailabs.astraldeep.app.transport.ConnectionState
import com.personalailabs.astraldeep.app.transport.OrchestratorClient
import com.personalailabs.astraldeep.app.ui.AppViewModel
import com.personalailabs.astraldeep.app.ui.DeviceObservation
import com.personalailabs.astraldeep.app.ui.RootScaffold
import com.personalailabs.astraldeep.app.ui.theme.AstralColors
import com.personalailabs.astraldeep.app.ui.theme.AstralTheme
import com.personalailabs.astraldeep.app.voice.LiveKitVoiceMediaClient
import com.personalailabs.astraldeep.app.voice.OkHttpVoiceControlApi
import com.personalailabs.astraldeep.app.voice.VoiceSessionController
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

class MainActivity : ComponentActivity() {
    private val canvasCapture = CanvasCaptureRegistry()
    private val componentActions by lazy { ComponentActionController(this, { authToken.value }) }
    private val workspaceActions by lazy { WorkspaceActionController(this, { authToken.value }, canvasCapture) }

    private val authFence = AuthAttemptFence()
    private val serverScope by lazy {
        if (AppConfig.API_BASE.startsWith("https://")) {
            ServerSessionScope(AppConfig.API_BASE, AppConfig.KEYCLOAK_AUTHORITY, AppConfig.OIDC_CLIENT_ID, AppConfig.OIDC_REDIRECT_URI)
        } else {
            null
        }
    }
    private val serverTransport by lazy { serverScope?.let { ServerSessionTransport(it) } }
    private val serverSession by lazy { serverTransport?.let { ServerSessionCoordinator(it, store) } }
    private val client by lazy {
        OrchestratorClient(AppConfig.WS_URL, serverSession = {
            if (authFence.currentMode() == AuthAttemptFence.Mode.SERVER) {
                serverSession ?: throw ServerSessionException(ServerSessionException.Reason.RETIRED)
            } else {
                null
            }
        })
    }
    private val rest by lazy { AstralRest(AppConfig.API_BASE) }
    private val voiceScope by lazy { CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate) }
    private val voiceController by lazy {
        VoiceSessionController(
            api = OkHttpVoiceControlApi(AppConfig.API_BASE),
            media = LiveKitVoiceMediaClient(applicationContext, voiceScope),
            scope = voiceScope,
        )
    }
    private val oidc by lazy { OidcAuth(this) }
    private val keycloakLogout by lazy {
        KeycloakLogout(keycloakEndpoints(AppConfig.KEYCLOAK_AUTHORITY).endSessionEndpoint)
    }

    private data class PendingDownload(val url: String, val owner: ConversationResumeStore.AccountIdentity)

    private var pendingDownload: PendingDownload? = null
    private val saveDownload =
        registerForActivityResult(ActivityResultContracts.CreateDocument("*/*")) { uri ->
            val pending = pendingDownload
            pendingDownload = null
            if (uri != null && pending == null) {
                Toast.makeText(this, "Download expired. Select the file again.", Toast.LENGTH_LONG).show()
            }
            if (uri != null && pending != null) {
                lifecycleScope.launch {
                    try {
                        withContext(Dispatchers.IO) {
                            val token = authToken.value.orEmpty()
                            check(ConversationResumeStore.accountFromAccessToken(token) == pending.owner) { "Account changed" }
                            val temporary = File.createTempFile("astral-download-", ".tmp", cacheDir)
                            try {
                                temporary.outputStream().use { destination ->
                                    ArtifactDownload(AppConfig.API_BASE, allowLocalHttp = BuildConfig.DEBUG)
                                        .copyTo(pending.url, token, destination)
                                }
                                ensureActive()
                                check(
                                    ConversationResumeStore.accountFromAccessToken(authToken.value.orEmpty()) == pending.owner,
                                ) { "Account changed" }
                                val destination = contentResolver.openOutputStream(uri, "wt") ?: error("Could not open destination")
                                destination.use { output -> temporary.inputStream().use { it.copyTo(output) } }
                            } finally {
                                temporary.delete()
                            }
                        }
                        Toast.makeText(this@MainActivity, "File saved", Toast.LENGTH_SHORT).show()
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) {
                        Toast.makeText(
                            this@MainActivity,
                            "Download failed. Return to this account and try again.",
                            Toast.LENGTH_LONG,
                        ).show()
                    }
                }
            }
        }

    private fun downloadFile(
        url: String,
        filename: String,
    ) {
        if (pendingDownload != null) return
        try {
            publicDownloadBrowserUrl(AppConfig.API_BASE, url)?.let { publicUrl ->
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(publicUrl.toString())))
                return
            }
            val owner = ConversationResumeStore.accountFromAccessToken(authToken.value.orEmpty()) ?: error("Sign in required")
            artifactDownloadUrl(AppConfig.API_BASE, url, allowLocalHttp = BuildConfig.DEBUG)
            pendingDownload = PendingDownload(url, owner)
            saveDownload.launch(safeDownloadFilename(filename))
        } catch (_: Exception) {
            pendingDownload = null
            Toast.makeText(this, "This file cannot be downloaded securely from this server.", Toast.LENGTH_LONG).show()
        }
    }

    private val store by lazy { TokenStore(this) }
    private val conversationResumeStore by lazy { ConversationResumeStore(this) }
    private val authToken = MutableStateFlow<String?>(null)
    private val signInError = MutableStateFlow<String?>(null)

    private class PendingSignIn(
        val ticket: AuthAttemptFence.Ticket,
        val custody: ServerSessionCoordinator.Attempt?,
    )

    private var pendingSignIn: PendingSignIn? = null

    private val authLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val pending = pendingSignIn ?: return@registerForActivityResult
            pendingSignIn = null
            val data = result.data ?: return@registerForActivityResult
            lifecycleScope.launch(Dispatchers.IO) {
                try {
                    authFence.consume(pending.ticket)
                    val token =
                        if (pending.ticket.mode == AuthAttemptFence.Mode.SERVER) {
                            val scope = serverScope ?: throw ServerSessionException(ServerSessionException.Reason.INVALID)
                            val code = oidc.serverCode(data, scope)
                            checkNotNull(serverSession).exchange(checkNotNull(pending.custody), code)
                        } else {
                            val state = oidc.exchange(data)
                            val value = oidc.freshToken(state)
                            ensureActive()
                            authFence.guarded(pending.ticket) { store.save(state) }
                            value
                        }
                    applyAuthToken(token, pending.ticket)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    authFailure(pending.ticket, "Sign-in failed. Start sign-in again.")
                }
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        workspaceActions.invalidateStale()
        componentActions.invalidateStale()
        val initial = authFence.capture()
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                val restored = authFence.guarded(initial) { serverSession?.restore() == true }
                if (restored) {
                    authFence.select(initial, AuthAttemptFence.Mode.SERVER)
                    applyAuthToken(checkNotNull(serverSession).refresh(), initial)
                } else {
                    val st = authFence.guarded(initial) { store.load() } ?: return@launch
                    val cached = st.accessToken?.takeIf { it.isNotBlank() }
                    cached?.let { applyAuthToken(it, initial) }
                    val route =
                        routeAfterRefresh(
                            runCatching { oidc.freshToken(st) }.onSuccess {
                                ensureActive()
                                authFence.guarded(initial) { store.save(st) }
                            },
                            cachedToken = cached,
                        )
                    applyAuthToken(route.token, initial, route.error)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                authFailure(initial, "Could not resume this session. Try again.")
            }
        }
        setContent {
            val vm: AppViewModel =
                viewModel(factory = AppViewModel.factory(client, rest, conversationResumeStore, voiceController))
            val uiState by vm.state.collectAsStateWithLifecycle()
            AstralTheme(palette = uiState.themePalette) {
                val renderer =
                    remember(vm) {
                        Renderer(
                            Emit { a, p -> vm.sendEvent(a, p) },
                            Download { url, fn -> downloadFile(url, fn) },
                            ThemeSink { spec -> vm.applyTheme(spec) },
                        ).registerAllRenderers().also {
                            it.componentActions = componentActions.handler(vm)
                            it.capture = canvasCapture
                            it.captureContext = { vm.workspaceContext() }
                        }
                    }
                val token by authToken.collectAsStateWithLifecycle()
                val error by signInError.collectAsStateWithLifecycle()
                LaunchedEffect(uiState, token) {
                    if (vm.workspaceContext() == null) canvasCapture.clear()
                    workspaceActions.invalidateStale()
                    componentActions.invalidateStale()
                }

                if (token == null) {
                    SignInScreen(error = error, onSignIn = ::startSignIn)
                } else {
                    // Refresh failure must reach sign-in with an explanation, never fail silent
                    LaunchedEffect(uiState.connection) {
                        if (uiState.connection == ConnectionState.AuthRequired) {
                            val ticket = authFence.capture()
                            try {
                                val route =
                                    withContext(Dispatchers.IO) {
                                        if (ticket.mode == AuthAttemptFence.Mode.SERVER) {
                                            com.personalailabs.astraldeep.app.auth.AuthRoute(checkNotNull(serverSession).refresh(), null)
                                        } else {
                                            routeAfterRefresh(
                                                runCatching {
                                                    val st = authFence.guarded(ticket) { checkNotNull(store.load()) }
                                                    oidc.freshToken(st).also {
                                                        ensureActive()
                                                        authFence.guarded(ticket) { store.save(st) }
                                                    }
                                                },
                                            )
                                        }
                                    }
                                applyAuthToken(route.token, ticket, route.error)
                            } catch (cancelled: CancellationException) {
                                throw cancelled
                            } catch (_: Exception) {
                                authFailure(ticket, "Session unavailable. Sign in again.")
                            }
                        }
                    }
                    val componentShare by componentActions.share.collectAsStateWithLifecycle()
                    componentShare?.let { link ->
                        ComponentShareDialog(
                            link.url,
                            onCopy = { componentActions.copy(link) },
                            onDismiss = { componentActions.dismiss(link) },
                        )
                    }
                    DeviceObservation(vm, token!!, renderer.supportedTypes.toList()) {
                        RootScaffold(vm, renderer, onSignOut = { signOut(vm) }, onWorkspaceAction = { workspaceActions.perform(it, vm) })
                    }
                }
            }
        }
    }

    private suspend fun applyAuthToken(
        next: String?,
        ticket: AuthAttemptFence.Ticket,
        error: String? = null,
    ) = withContext(Dispatchers.Main.immediate) {
        ensureActive()
        authFence.publish(ticket) {
            val publish = {
                val oldOwner = ConversationResumeStore.accountFromAccessToken(authToken.value.orEmpty())
                val newOwner = ConversationResumeStore.accountFromAccessToken(next.orEmpty())
                if (next == null || oldOwner != newOwner) {
                    workspaceActions.clear()
                    componentActions.clear()
                }
                authToken.value = next
                signInError.value = error
            }
            if (next != null && ticket.mode == AuthAttemptFence.Mode.SERVER) {
                checkNotNull(serverSession).withToken(next, publish)
            } else {
                publish()
            }
        }
    }

    private suspend fun authFailure(
        ticket: AuthAttemptFence.Ticket,
        message: String,
    ) {
        withContext(Dispatchers.Main.immediate) {
            try {
                authFence.guarded(ticket) {
                    if (ticket.mode == AuthAttemptFence.Mode.SERVER) {
                        client.clearOwnerSession()
                        workspaceActions.clear()
                        componentActions.clear()
                        authToken.value = null
                    }
                    signInError.value = message
                }
            } catch (_: ServerSessionException) {
                // A newer attempt owns the UI.
            }
        }
    }

    private fun startSignIn() {
        val ticket = authFence.begin()
        pendingSignIn = null
        lifecycleScope.launch {
            try {
                // A failed HTTPS probe never authorizes a legacy fallback
                val transport = serverTransport ?: throw ServerSessionException(ServerSessionException.Reason.UNAVAILABLE)
                val selected = withContext(Dispatchers.IO) { transport.probe() }
                ensureActive()
                if (ticket.mode == AuthAttemptFence.Mode.SERVER && !selected) {
                    throw ServerSessionException(ServerSessionException.Reason.UNAVAILABLE)
                }
                authFence.select(ticket, if (selected) AuthAttemptFence.Mode.SERVER else AuthAttemptFence.Mode.LEGACY)
                authFence.guarded(ticket) {
                    val custody = if (selected) checkNotNull(serverSession).begin() else null
                    val intent = if (selected) oidc.authorizeServerIntent(checkNotNull(serverScope)) else oidc.authorizeIntent()
                    pendingSignIn = PendingSignIn(ticket, custody)
                    authLauncher.launch(intent)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                authFailure(ticket, "Could not start secure sign-in. Try again.")
            }
        }
    }

    private fun signOut(vm: AppViewModel) {
        val custodyMode = authFence.currentMode() == AuthAttemptFence.Mode.SERVER
        authFence.retire()
        pendingSignIn = null
        val retired = if (custodyMode) runCatching { serverSession?.retire() }.getOrNull() else null
        workspaceActions.clear()
        componentActions.clear()
        voiceController.logout()
        // Clear session synchronously first; async clear risked a stuck sign-in
        val st = runCatching { store.load() }.getOrNull()
        val access = authToken.value ?: st?.accessToken
        val refresh = st?.refreshToken
        access
            ?.let(ConversationResumeStore::accountFromAccessToken)
            ?.let { account ->
                if (!conversationResumeStore.clear(account, ClearReason.DEFINITIVE_SIGN_OUT)) {
                    Log.w("MainActivity", "conversation locator clear failed during sign-out")
                }
            }
        vm.signOut {
            pendingDownload = null
            store.clear()
            signInError.value = null
            authToken.value = null
        }
        if (custodyMode) {
            if (retired != null) {
                lifecycleScope.launch(Dispatchers.IO) {
                    try {
                        serverSession?.logout(retired)
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) {
                        Log.w("MainActivity", "Server session logout unconfirmed")
                    }
                }
            }
            return
        }
        if (refresh.isNullOrBlank()) return
        lifecycleScope.launch(Dispatchers.IO) {
            val viaBackend =
                access != null &&
                    runCatching { rest.logout(access, refresh, AppConfig.OIDC_CLIENT_ID) }.getOrDefault(false)
            val outcome =
                if (viaBackend) {
                    "backend"
                } else if (runCatching { keycloakLogout.revoke(AppConfig.OIDC_CLIENT_ID, refresh) }.getOrDefault(false)) {
                    "keycloak"
                } else {
                    "unrevoked"
                }
            Log.i("MainActivity", "sign-out revocation: $outcome")
        }
    }

    override fun onDestroy() {
        authFence.retire()
        pendingSignIn = null
        workspaceActions.clear()
        componentActions.clear()
        oidc.dispose()
        super.onDestroy()
    }
}

@Composable
private fun SignInScreen(
    error: String?,
    onSignIn: () -> Unit,
) {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Box(
            modifier = Modifier.fillMaxSize().background(AstralColors.BackdropBrush).padding(28.dp),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
                modifier = Modifier.widthIn(max = 420.dp).fillMaxWidth(),
            ) {
                Image(
                    painter = painterResource(R.drawable.astral_logo),
                    contentDescription = "AstralDeep",
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxWidth(0.78f).height(96.dp),
                )
                Spacer(Modifier.height(14.dp))
                Text(
                    text = "Your adaptive AI workspace",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 15.sp,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(40.dp))
                GradientButton(text = "Sign in", onClick = onSignIn)
                error?.let {
                    Spacer(Modifier.height(18.dp))
                    Text(
                        text = it,
                        color = MaterialTheme.colorScheme.error,
                        fontSize = 13.sp,
                        textAlign = TextAlign.Center,
                    )
                }
                Spacer(Modifier.height(28.dp))
                Text(
                    text = "Secured by Keycloak",
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                    fontSize = 12.sp,
                )
            }
        }
    }
}

@Composable
private fun GradientButton(
    text: String,
    onClick: () -> Unit,
) {
    Box(
        modifier =
            Modifier
                .widthIn(min = 220.dp)
                .clip(RoundedCornerShape(26.dp))
                .background(AstralColors.AccentBrush)
                .clickable(onClick = onClick)
                .padding(vertical = 15.dp, horizontal = 32.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text = text, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
    }
}
