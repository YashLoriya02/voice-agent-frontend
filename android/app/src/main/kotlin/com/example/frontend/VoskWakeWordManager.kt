package com.example.frontend

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import org.json.JSONObject
import org.vosk.LibVosk
import org.vosk.LogLevel
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.RecognitionListener
import org.vosk.android.SpeechService
import org.vosk.android.StorageService
import java.util.Locale

/**
 * Account-free, on-device wake phrase listener shared by the Flutter activity
 * and Android's selected VoiceInteractionService.
 *
 * The recognizer has a restricted grammar so it only needs to distinguish the
 * wake phrase from unknown speech. It shuts down AudioRecord before notifying
 * Flutter of a detection; this is essential for the Groq/Deepgram handoff.
 */
class VoskWakeWordManager(
    context: Context,
    private val emit: (String, Map<String, Any?>) -> Unit,
) : RecognitionListener {

    private val context = context.applicationContext

    companion object {
        private const val TAG = "WakeWord/Vosk"
        private const val MODEL_ASSET = "model-en-us"
        private const val MODEL_TARGET = "vosk-wake-model-v1"
        private const val SAMPLE_RATE = 16_000.0f
        private const val DETECTION_DELAY_MS = 150L
        private const val GRAMMAR =
            "[\"hey agent\", \"hay agent\", \"hey agents\", \"[unk]\"]"

        private val WAKE_PHRASE = Regex("\\b(?:hey|hay)\\s+agents?\\b")
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private var model: Model? = null
    private var recognizer: Recognizer? = null
    private var speechService: SpeechService? = null
    private var initializing = false
    private var desiredListening = false
    private var detectionInProgress = false
    private var disposed = false

    init {
        LibVosk.setLogLevel(LogLevel.INFO)
    }

    fun initialize() {
        if (disposed) return

        if (model != null) {
            emitState("ready", "Say “Hey Agent”")
            if (desiredListening) startRecognition()
            return
        }

        if (initializing) return
        initializing = true
        emitState("initializing", "Loading offline Hey Agent...")
        Log.i(TAG, "Unpacking bundled Vosk model '$MODEL_ASSET'.")

        StorageService.unpack(
            context,
            MODEL_ASSET,
            MODEL_TARGET,
            { loadedModel ->
                initializing = false

                if (disposed) {
                    loadedModel.close()
                } else {
                    model = loadedModel
                    Log.i(TAG, "Vosk model is ready.")
                    emitState("ready", "Say “Hey Agent”")
                    if (desiredListening) startRecognition()
                }
            },
            { exception ->
                initializing = false
                desiredListening = false
                Log.e(TAG, "Unable to unpack Vosk model.", exception)
                emitState("error", "Hey Agent model could not be loaded.")
            },
        )
    }

    fun start() {
        if (disposed) return
        desiredListening = true

        if (model == null) {
            initialize()
            return
        }

        startRecognition()
    }

    fun onMicrophonePermissionResult(granted: Boolean) {
        if (disposed) return

        if (granted) {
            start()
        } else {
            desiredListening = false
            emitState("error", "Microphone permission is required for Hey Agent.")
        }
    }

    @Synchronized
    private fun startRecognition() {
        if (
            disposed ||
            !desiredListening ||
            speechService != null ||
            detectionInProgress
        ) {
            return
        }

        if (
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.RECORD_AUDIO,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            desiredListening = false
            Log.e(TAG, "RECORD_AUDIO permission is not granted.")
            emitState("error", "Microphone permission is required for Hey Agent.")
            return
        }

        val loadedModel = model ?: return

        try {
            val nextRecognizer = Recognizer(
                loadedModel,
                SAMPLE_RATE,
                GRAMMAR,
            )
            val nextService = SpeechService(nextRecognizer, SAMPLE_RATE)

            recognizer = nextRecognizer
            speechService = nextService

            if (!nextService.startListening(this)) {
                throw IllegalStateException("Vosk microphone listener did not start.")
            }

            Log.i(TAG, "Listening at 16 kHz with restricted Hey Agent grammar.")
            emitState("listening", "Listening for “Hey Agent”")
        } catch (exception: Exception) {
            Log.e(TAG, "Unable to start Vosk recognition.", exception)
            releaseRecognition()
            desiredListening = false
            emitState("error", "Could not start Hey Agent microphone.")
        }
    }

    fun stop() {
        desiredListening = false
        detectionInProgress = false
        releaseRecognition()

        if (!disposed && model != null) {
            emitState("ready", "Say “Hey Agent”")
        }
    }

    @Synchronized
    private fun releaseRecognition() {
        val service = speechService
        speechService = null

        try {
            service?.cancel()
        } catch (exception: Exception) {
            Log.w(TAG, "Vosk cancel failed.", exception)
        }

        try {
            service?.shutdown()
        } catch (exception: Exception) {
            Log.w(TAG, "Vosk shutdown failed.", exception)
        }

        val currentRecognizer = recognizer
        recognizer = null
        try {
            currentRecognizer?.close()
        } catch (exception: Exception) {
            Log.w(TAG, "Vosk recognizer close failed.", exception)
        }

        if (service != null) {
            Log.i(TAG, "Vosk microphone released.")
        }
    }

    override fun onPartialResult(hypothesis: String?) {
        handleHypothesis(hypothesis, partial = true)
    }

    override fun onResult(hypothesis: String?) {
        handleHypothesis(hypothesis, partial = false)
    }

    override fun onFinalResult(hypothesis: String?) {
        handleHypothesis(hypothesis, partial = false)
    }

    private fun handleHypothesis(hypothesis: String?, partial: Boolean) {
        if (disposed || detectionInProgress || hypothesis.isNullOrBlank()) return

        val key = if (partial) "partial" else "text"
        val text = try {
            JSONObject(hypothesis).optString(key).trim()
        } catch (exception: Exception) {
            Log.w(TAG, "Invalid Vosk result: $hypothesis", exception)
            return
        }

        if (text.isBlank()) return
        Log.d(TAG, "${if (partial) "Partial" else "Result"}: $text")
        emit("partial", mapOf("text" to text))

        val normalized = text.lowercase(Locale.ROOT)
        if (WAKE_PHRASE.containsMatchIn(normalized)) {
            dispatchDetection(text)
        }
    }

    @Synchronized
    private fun dispatchDetection(text: String) {
        if (disposed || detectionInProgress) return

        detectionInProgress = true
        desiredListening = false
        Log.i(TAG, "Wake phrase detected: '$text'.")

        // cancel + shutdown release AudioRecord. Only then may Flutter start
        // the selected provider's recorder.
        releaseRecognition()
        emitState("detected", "Hey Agent detected")

        mainHandler.postDelayed(
            {
                if (!disposed) {
                    emit("detected", mapOf("text" to text))
                }
                detectionInProgress = false
            },
            DETECTION_DELAY_MS,
        )
    }

    override fun onError(exception: Exception?) {
        Log.e(TAG, "Vosk recognition error.", exception)
        releaseRecognition()
        desiredListening = false
        detectionInProgress = false
        emitState("error", "Hey Agent microphone error.")
    }

    override fun onTimeout() {
        Log.i(TAG, "Vosk recognition timeout.")
        releaseRecognition()

        if (desiredListening && !disposed) {
            startRecognition()
        }
    }

    fun dispose() {
        if (disposed) return
        desiredListening = false
        detectionInProgress = false
        releaseRecognition()
        model?.close()
        model = null
        disposed = true
        mainHandler.removeCallbacksAndMessages(null)
        Log.i(TAG, "Disposed Vosk wake listener.")
    }

    private fun emitState(state: String, message: String) {
        emit(
            "state",
            mapOf(
                "state" to state,
                "message" to message,
            ),
        )
    }
}
