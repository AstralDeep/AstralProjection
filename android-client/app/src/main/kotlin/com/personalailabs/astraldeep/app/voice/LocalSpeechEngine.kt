// Client-local speech readiness for Android: a pure readiness ladder over observed platform facts,
// the client_capability wire body it produces, and the recognition/synthesis engine interface the
// local voice runtime drives. AndroidLocalSpeechEngine binds it to SpeechRecognizer and TextToSpeech.

package com.personalailabs.astraldeep.app.voice

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.personalailabs.astraldeep.app.transport.runtimeVoiceCapability
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

data class LocalSpeechFacts(
    val hasMicrophone: Boolean,
    val hasAudioOutput: Boolean,
    val microphonePermission: String,
    val recognitionServiceAvailable: Boolean,
    val recognitionOnDevice: Boolean,
    val recognitionLocaleState: String,
    val recognitionInstallation: String,
    val synthesisEngineReady: Boolean,
    val synthesisLocaleState: String,
)

data class LocalSpeechCapability(
    val hasMicrophone: Boolean,
    val hasAudioOutput: Boolean,
    val microphonePermission: String,
    val recognitionPermission: String,
) {
    fun toJson(): JsonObject =
        buildJsonObject {
            put("contract", "client_local/v1")
            put("transport", "client_local")
            put("configured_locale", "en-US")
            put("full_duplex", false)
            put("has_microphone", hasMicrophone)
            put("has_audio_output", hasAudioOutput)
            put("microphone_permission", microphonePermission)
            put("recognition_permission", recognitionPermission)
            put("recognition_processing", "guaranteed_local")
            put("recognition_locale", "ready")
            put("recognition_installation", "ready")
            put("synthesis_processing", "guaranteed_local")
            put("synthesis_locale", "ready")
        }
}

data class LocalSpeechVerdict(
    val eligible: Boolean,
    val reason: String?,
    val installable: Boolean,
    val capability: LocalSpeechCapability?,
)

object LocalSpeechReadiness {
    fun evaluate(facts: LocalSpeechFacts): LocalSpeechVerdict {
        val reason = refusalReason(facts)
        if (reason != null) {
            return LocalSpeechVerdict(
                eligible = false,
                reason = reason,
                installable = reason in INSTALLABLE_REASONS,
                capability = null,
            )
        }
        return LocalSpeechVerdict(
            eligible = true,
            reason = null,
            installable = false,
            capability =
                LocalSpeechCapability(
                    hasMicrophone = facts.hasMicrophone,
                    hasAudioOutput = facts.hasAudioOutput,
                    microphonePermission = facts.microphonePermission,
                    recognitionPermission = facts.microphonePermission,
                ),
        )
    }

    private fun refusalReason(facts: LocalSpeechFacts): String? =
        when {
            !facts.hasMicrophone -> "no_microphone"
            !facts.hasAudioOutput -> "no_audio_output"
            facts.microphonePermission in DENIED_PERMISSIONS -> "microphone_permission_denied"
            facts.microphonePermission != "authorized" -> "microphone_permission_not_determined"
            !facts.recognitionServiceAvailable -> "local_recognition_unavailable"
            !facts.recognitionOnDevice -> "local_processing_not_guaranteed"
            facts.recognitionInstallation == "downloadable" -> "local_language_download_required"
            facts.recognitionInstallation == "installing" -> "local_language_installing"
            facts.recognitionInstallation == "failed" -> "local_language_install_failed"
            facts.recognitionInstallation in setOf("unavailable", "not_applicable") -> "local_recognition_unavailable"
            facts.recognitionLocaleState != "ready" -> "local_recognition_locale_unavailable"
            !facts.synthesisEngineReady -> "local_synthesis_unavailable"
            facts.synthesisLocaleState != "ready" -> "local_synthesis_locale_unavailable"
            else -> null
        }

    private val DENIED_PERMISSIONS = setOf("denied", "restricted", "unavailable")
    private val INSTALLABLE_REASONS = setOf("local_language_download_required", "local_language_installing")
}

interface LocalSpeechEngine {
    suspend fun probe(): LocalSpeechFacts

    fun startRecognition(
        onPartial: (String) -> Unit,
        onFinal: (String) -> Unit,
        onError: (String) -> Unit,
    ): Boolean

    fun stopRecognition()

    fun stopAll()

    fun speak(
        text: String,
        locale: String,
        onStarted: () -> Unit,
        onDone: (Boolean) -> Unit,
    ): Boolean
}

class AndroidLocalSpeechEngine(
    private val context: Context,
) : LocalSpeechEngine {
    private val engineRef = AtomicReference<TextToSpeech?>(null)
    private val synthesisReady = AtomicBoolean(false)
    private val initLatch = CountDownLatch(1)
    private var currentRecognizer: SpeechRecognizer? = null

    init {
        Thread {
            val created =
                runCatching {
                    TextToSpeech(context.applicationContext) { status ->
                        synthesisReady.set(status == TextToSpeech.SUCCESS)
                        initLatch.countDown()
                    }
                }.getOrNull()
            engineRef.set(created)
            if (created == null) initLatch.countDown()
        }.start()
    }

    override suspend fun probe(): LocalSpeechFacts =
        withContext(Dispatchers.IO) {
            initLatch.await(PROBE_WAIT_SECONDS, TimeUnit.SECONDS)
            val voice = runtimeVoiceCapability(context)
            val onDevice =
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
            val ready = synthesisReady.get()
            val recognitionLocale = if (onDevice) "ready" else "unknown"
            val recognitionInstallation = if (onDevice) "ready" else "unavailable"
            LocalSpeechFacts(
                hasMicrophone = voice.hasMicrophone,
                hasAudioOutput = voice.hasAudioOutput,
                microphonePermission = voice.microphonePermission,
                recognitionServiceAvailable = SpeechRecognizer.isRecognitionAvailable(context),
                recognitionOnDevice = onDevice,
                recognitionLocaleState = recognitionLocale,
                recognitionInstallation = recognitionInstallation,
                synthesisEngineReady = ready && localVoiceReady(engineRef.get()),
                synthesisLocaleState = if (ready && localVoiceReady(engineRef.get())) "ready" else "unknown",
            )
        }

    override fun startRecognition(
        onPartial: (String) -> Unit,
        onFinal: (String) -> Unit,
        onError: (String) -> Unit,
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        val recognizer =
            runCatching { SpeechRecognizer.createOnDeviceSpeechRecognizer(context) }.getOrNull()
                ?: return false
        val reportPartial = onPartial
        val reportFinal = onFinal
        val reportError = onError
        val listener =
            object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) = Unit

                override fun onBeginningOfSpeech() = Unit

                override fun onRmsChanged(rmsdB: Float) = Unit

                override fun onBufferReceived(buffer: ByteArray?) = Unit

                override fun onEndOfSpeech() = Unit

                override fun onError(error: Int) {
                    release()
                    reportError("local_recognition_failed")
                }

                override fun onResults(results: Bundle?) {
                    release()
                    val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                    if (text.isNullOrEmpty()) {
                        reportError("local_final_empty")
                    } else {
                        reportFinal(text)
                    }
                }

                override fun onPartialResults(partialResults: Bundle?) {
                    val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                    if (!text.isNullOrEmpty()) reportPartial(text)
                }

                override fun onEvent(eventType: Int, params: Bundle?) = Unit
            }
        val started =
            runCatching {
                recognizer.setRecognitionListener(listener)
                recognizer.startListening(
                    Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                        putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-US")
                        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                    },
                )
            }.isSuccess
        if (!started) {
            runCatching { recognizer.destroy() }
            return false
        }
        currentRecognizer = recognizer
        return true
    }

    override fun stopRecognition() {
        currentRecognizer?.let { recognizer ->
            runCatching { recognizer.stopListening() }
            runCatching { recognizer.destroy() }
        }
        currentRecognizer = null
    }

    override fun stopAll() {
        stopRecognition()
        engineRef.get()?.let { engine -> runCatching { engine.stop() } }
    }

    override fun speak(
        text: String,
        locale: String,
        onStarted: () -> Unit,
        onDone: (Boolean) -> Unit,
    ): Boolean {
        val engine = engineRef.get() ?: return false
        if (!synthesisReady.get()) return false
        val language = runCatching { engine.setLanguage(Locale.forLanguageTag(locale)) }.getOrNull() ?: return false
        if (language < TextToSpeech.LANG_COUNTRY_AVAILABLE) return false
        val listener =
            object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {
                    onStarted()
                }

                override fun onDone(utteranceId: String?) {
                    runCatching { engine.setOnUtteranceProgressListener(null) }
                    onDone(true)
                }

                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String?) {
                    runCatching { engine.setOnUtteranceProgressListener(null) }
                    onDone(false)
                }

                override fun onError(utteranceId: String?, errorCode: Int) {
                    runCatching { engine.setOnUtteranceProgressListener(null) }
                    onDone(false)
                }
            }
        return runCatching {
            engine.setOnUtteranceProgressListener(listener)
            engine.speak(text, TextToSpeech.QUEUE_ADD, null, "astral-local-announcement-${System.nanoTime()}") != TextToSpeech.ERROR
        }.getOrDefault(false)
    }

    private fun localVoiceReady(engine: TextToSpeech?): Boolean {
        val active = engine ?: return false
        val voices = runCatching { active.voices }.getOrNull() ?: return false
        return voices.any { voice ->
            voice.locale.language == "en" &&
                voice.locale.country in setOf("US", "") &&
                !voice.isNetworkConnectionRequired &&
                !voice.features.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)
        }
    }

    private fun release() {
        currentRecognizer?.let { recognizer -> runCatching { recognizer.destroy() } }
        currentRecognizer = null
    }

    companion object {
        private const val PROBE_WAIT_SECONDS = 2L
    }
}
