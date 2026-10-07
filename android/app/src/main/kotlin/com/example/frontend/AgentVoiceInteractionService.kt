package com.example.frontend

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.voice.VoiceInteractionService
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Android's system-managed assistant service. Once the user selects this app
 * as the default assistant, Android keeps this lightweight service available
 * while the Flutter activity is closed.
 */
class AgentVoiceInteractionService : VoiceInteractionService() {
    companion object {
        private const val TAG = "HeyAgent/Assistant"
        const val EXTRA_WAKE_ACTIVATION = "hey_agent_wake_activation"

        @Volatile
        private var activeInstance: AgentVoiceInteractionService? = null

        fun isSelected(context: Context): Boolean {
            return VoiceInteractionService.isActiveService(
                context,
                ComponentName(context, AgentVoiceInteractionService::class.java),
            )
        }

        fun startSelectedListener(context: Context): Boolean {
            val instance = activeInstance ?: return false
            if (!isSelected(context)) return false
            instance.startWakeWordIfAllowed()
            return true
        }

        fun scheduleSelectedListener(context: Context) {
            val instance = activeInstance ?: return
            if (!isSelected(context)) return
            instance.mainHandler.removeCallbacks(instance.restartListener)
            // Flutter recorder cleanup and activity lifecycle callbacks finish
            // before the system assistant reacquires AudioRecord.
            instance.mainHandler.postDelayed(instance.restartListener, 500L)
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val restartListener = Runnable { startWakeWordIfAllowed() }

    private val wakeListener: (String, Map<String, Any?>) -> Unit =
        { method, arguments ->
            if (method == "detected") {
                val phrase = arguments["text"]?.toString() ?: "hey agent"
                mainHandler.post { openAssistantSession(phrase) }
            }
        }

    override fun onReady() {
        super.onReady()
        activeInstance = this
        WakeWordRuntime.addListener(wakeListener)
        Log.i(TAG, "Selected assistant is ready.")
        startWakeWordIfAllowed()
    }

    override fun onShutdown() {
        mainHandler.removeCallbacksAndMessages(null)
        Log.i(TAG, "Assistant role is shutting down.")
        if (activeInstance === this) activeInstance = null
        WakeWordRuntime.removeListener(wakeListener)
        WakeWordRuntime.stop()
        super.onShutdown()
    }

    override fun onDestroy() {
        mainHandler.removeCallbacksAndMessages(null)
        if (activeInstance === this) activeInstance = null
        WakeWordRuntime.removeListener(wakeListener)
        super.onDestroy()
    }

    fun startWakeWordIfAllowed() {
        if (!WakeWordRuntime.canListenAfterAssistant) {
            Log.i(TAG, "Wake restart deferred until the assistant host releases the microphone.")
            return
        }
        if (!AssistantPreferences.isWakeEnabled(this)) {
            Log.i(TAG, "Wake word is disabled by the user.")
            WakeWordRuntime.stop()
            return
        }

        if (
            ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "Microphone permission is not granted.")
            return
        }

        WakeWordRuntime.initialize(this)
        WakeWordRuntime.start(this)
    }

    private fun openAssistantSession(phrase: String) {
        if (!isSelected(this)) return

        Log.i(TAG, "Opening assistant session for '$phrase'.")
        val args = Bundle().apply {
            putString("wake_phrase", phrase)
        }
        showSession(args, 0)
    }
}
