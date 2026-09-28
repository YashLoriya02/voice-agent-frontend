package com.example.frontend

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.voice.VoiceInteractionSession
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import java.util.Locale
import java.util.UUID

/** Immediate native overlay shown before Flutter needs to cold-start. */
class AgentVoiceInteractionSession(context: Context) :
    VoiceInteractionSession(context) {

    companion object {
        private const val GREETING = "Hey, how may I help you?"
        private const val POST_GREETING_DELAY_MS = 900L
        private const val TTS_FALLBACK_TIMEOUT_MS = 6_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val sessionContext = context
    private var textToSpeech: TextToSpeech? = null
    private var ttsReady = false
    private var greetingPending = false
    private var launched = false
    private var nudgeView: HeyAgentNudgeView? = null

    override fun onCreate() {
        super.onCreate()
        textToSpeech = TextToSpeech(sessionContext) { status ->
            ttsReady = status == TextToSpeech.SUCCESS
            if (ttsReady) {
                textToSpeech?.language = Locale.US
                textToSpeech?.setSpeechRate(1.05f)
                textToSpeech?.setPitch(1.0f)
                textToSpeech?.setOnUtteranceProgressListener(
                    object : UtteranceProgressListener() {
                        override fun onStart(utteranceId: String?) {
                            mainHandler.post {
                                nudgeView?.updateCopy(
                                    subtitle = "HOW MAY I HELP?",
                                    status = "VOICE LINK ACTIVE",
                                )
                            }
                        }

                        override fun onDone(utteranceId: String?) {
                            mainHandler.post {
                                val provider =
                                    if (
                                        AssistantPreferences.preferredProvider(sessionContext) ==
                                        "deepgramVoiceAgent"
                                    ) {
                                        "CONNECTING DEEPGRAM"
                                    } else {
                                        "CONNECTING GROQ"
                                    }
                                nudgeView?.updateCopy(
                                    subtitle = provider,
                                    status = "SECURE HANDOFF IN PROGRESS",
                                )
                                mainHandler.postDelayed(
                                    { launchFlutterAgent() },
                                    POST_GREETING_DELAY_MS,
                                )
                            }
                        }

                        @Deprecated("Deprecated by Android")
                        override fun onError(utteranceId: String?) {
                            mainHandler.post { launchFlutterAgent() }
                        }

                        override fun onError(utteranceId: String?, errorCode: Int) {
                            mainHandler.post { launchFlutterAgent() }
                        }
                    },
                )
            }

            if (greetingPending) speakGreeting()
        }
    }

    override fun onCreateContentView(): View {
        val card = HeyAgentNudgeView(sessionContext).apply {
            updateCopy("INITIALIZING VOICE LINK", "NEURAL CORE ONLINE")
        }
        nudgeView = card

        return LinearLayout(sessionContext).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            setPadding(dp(18), dp(18), dp(18), dp(34))
            setBackgroundColor(Color.TRANSPARENT)
            addView(
                card,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ).apply {
                    bottomMargin = dp(10)
                },
            )
        }
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        launched = false
        greetingPending = true
        speakGreeting()
        // Never leave the assistant card stuck if a device TTS engine fails to
        // initialize or omits its completion callback.
        mainHandler.postDelayed(
            { if (!launched) launchFlutterAgent() },
            TTS_FALLBACK_TIMEOUT_MS,
        )
    }

    override fun onHide() {
        textToSpeech?.stop()
        super.onHide()
    }

    override fun onDestroy() {
        mainHandler.removeCallbacksAndMessages(null)
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        super.onDestroy()
    }

    private fun speakGreeting() {
        if (!greetingPending) return
        if (!ttsReady) {
            if (textToSpeech == null) launchFlutterAgent()
            return
        }

        greetingPending = false
        val utteranceId = "hey-agent-${UUID.randomUUID()}"
        val result = textToSpeech?.speak(
            GREETING,
            TextToSpeech.QUEUE_FLUSH,
            Bundle(),
            utteranceId,
        )

        if (result == TextToSpeech.ERROR) {
            launchFlutterAgent()
        }
    }

    private fun launchFlutterAgent() {
        if (launched) return
        launched = true
        AssistantActivationStore.markPending()

        val intent = Intent(sessionContext, MainActivity::class.java).apply {
            putExtra(AgentVoiceInteractionService.EXTRA_WAKE_ACTIVATION, true)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        }

        try {
            startAssistantActivity(intent)
        } catch (_: Exception) {
            sessionContext.startActivity(intent)
        }
        hide()
    }

    private fun dp(value: Int): Int {
        return (value * sessionContext.resources.displayMetrics.density).toInt()
    }
}
