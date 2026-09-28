package com.example.frontend

import android.content.Intent
import android.speech.RecognitionService
import android.speech.SpeechRecognizer

/**
 * Required assistant-role recognition component. Actual wake detection is
 * handled locally by Vosk in AgentVoiceInteractionService.
 */
class AgentRecognitionService : RecognitionService() {
    override fun onStartListening(recognizerIntent: Intent, listener: Callback) {
        listener.error(SpeechRecognizer.ERROR_CLIENT)
    }

    override fun onStopListening(listener: Callback) = Unit

    override fun onCancel(listener: Callback) = Unit
}
