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
import android.graphics.drawable.ColorDrawable
import android.view.WindowManager
import android.view.View
import android.view.ViewGroup
import java.util.Locale
import java.util.UUID

/** Immediate native overlay shown before Flutter needs to cold-start. */
class AgentVoiceInteractionSession(context: Context) :
    VoiceInteractionSession(context) {

    companion object {
        private const val GREETING = "Hey, how may I help you?"
        private const val POST_GREETING_DELAY_MS = 900L
        private const val TTS_FALLBACK_TIMEOUT_MS = 6_000L

        @Volatile
        private var activeSession: AgentVoiceInteractionSession? = null

        fun dismissActiveSession() {
            val session = activeSession ?: return
            session.mainHandler.post { session.hide() }
        }
        fun updateActiveState(phase: String, caption: String) {
            val session = activeSession ?: return
            session.mainHandler.post { session.overlay?.updateState(phase, caption) }
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val sessionContext = context
    private var textToSpeech: TextToSpeech? = null
    private var ttsReady = false
    private var greetingPending = false
    private var launched = false
    private var nudgeView: HeyAgentNudgeView? = null
    private var overlay: AssistantOverlayView? = null

    override fun onCreate() {
        super.onCreate()
        activeSession = this
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
                                    subtitle = "HELLO",
                                    status = "How can I help?",
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
                                        "DEEPGRAM VOICE"
                                    } else {
                                        "CUSTOM VOICE"
                                    }
                                nudgeView?.updateCopy(
                                    subtitle = "GETTING READY",
                                    status = provider,
                                )
                                mainHandler.postDelayed(
                                    { startBackgroundFlutterAgent() },
                                    POST_GREETING_DELAY_MS,
                                )
                            }
                        }

                        @Deprecated("Deprecated by Android")
                        override fun onError(utteranceId: String?) {
                            mainHandler.post { startBackgroundFlutterAgent() }
                        }

                        override fun onError(utteranceId: String?, errorCode: Int) {
                            mainHandler.post { startBackgroundFlutterAgent() }
                        }
                    },
                )
            }

            if (greetingPending) speakGreeting()
        }
    }

    override fun onCreateContentView(): View {
        val root = AssistantOverlayView(sessionContext, onDismiss = { hide() })
        overlay = root
        nudgeView = root.panel
        root.panel.updateCopy("GETTING READY", "How can I help?")
        return root
    }

    override fun onComputeInsets(outInsets: Insets) {
        val root = overlay
        outInsets.contentInsets.set(0, root?.height ?: 0, 0, 0)
        outInsets.touchableInsets = Insets.TOUCHABLE_INSETS_REGION
        outInsets.touchableRegion.setEmpty()
        root?.panel?.let { panel ->
            val position = IntArray(2)
            panel.getLocationInWindow(position)
            outInsets.touchableRegion.set(position[0], position[1], position[0] + panel.width, position[1] + panel.height)
        }
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        getWindow().window?.apply {
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL)
            androidx.core.view.WindowCompat.setDecorFitsSystemWindows(this, false)
            if (android.os.Build.VERSION.SDK_INT >= 28) attributes = attributes.apply { layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES }
        }
        overlay?.setActive(true)
        overlay?.updateState("idle", "How can I help?")
        launched = false
        greetingPending = true
        speakGreeting()
        // Never leave the assistant card stuck if a device TTS engine fails to
        // initialize or omits its completion callback.
        mainHandler.postDelayed(
            { if (!launched) startBackgroundFlutterAgent() },
            TTS_FALLBACK_TIMEOUT_MS,
        )
    }

    override fun onHide() {
        overlay?.setActive(false)
        textToSpeech?.stop()
        AssistantHostActivity.finishActive()
        super.onHide()
    }

    override fun onDestroy() {
        mainHandler.removeCallbacksAndMessages(null)
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        if (activeSession === this) activeSession = null
        super.onDestroy()
    }

    private fun speakGreeting() {
        if (!greetingPending) return
        if (!ttsReady) {
            if (textToSpeech == null) startBackgroundFlutterAgent()
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
            startBackgroundFlutterAgent()
        }
    }

    private fun startBackgroundFlutterAgent() {
        if (launched) return
        launched = true
        AssistantActivationStore.markPending()

        val intent = Intent(sessionContext, AssistantHostActivity::class.java).apply {
            putExtra(AgentVoiceInteractionService.EXTRA_WAKE_ACTIVATION, true)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        }

        try {
            // A voice activity is placed underneath this session, so the
            // native nudge remains visible while Flutter runs the mic,
            // provider, tools and TTS invisibly.
            startVoiceActivity(intent)
        } catch (_: Exception) {
            sessionContext.startActivity(intent)
        }
    }

}
