package com.example.frontend

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale

/** Message text is synthesized only with an installed voice requiring no network. */
class LocalMessageSpeech(private val context: Context) {
    private val handler = Handler(Looper.getMainLooper())
    private var engine: TextToSpeech? = null
    private var initialized = false
    private var pending: ((Boolean, String) -> Unit)? = null
    private var text = ""
    private var utteranceId = 0L
    private var timeout: Runnable? = null

    fun speak(readout: String, done: (Boolean, String) -> Unit) {
        val audio = context.getSystemService(AudioManager::class.java)
        if (audio.getStreamVolume(AudioManager.STREAM_MUSIC) == 0) {
            done(false, "Media volume is muted. Increase it before reading messages.")
            return
        }
        if (pending != null) {
            done(false, "A message readout is already playing. Stop it before starting another.")
            return
        }
        pending = done
        text = SpokenText.clean(readout)
        if (text.isEmpty()) {
            finish(true, "No spoken text in this readout.")
            return
        }
        timeout = Runnable { finish(false, "Message reading timed out. Please try again.") }
            .also { handler.postDelayed(it, 120_000) }
        if (engine == null) {
            engine = TextToSpeech(context.applicationContext) { status ->
                handler.post {
                    if (status != TextToSpeech.SUCCESS) {
                        engine?.shutdown()
                        engine = null
                        finish(false, "Android speech is unavailable. Install an offline voice in text-to-speech settings.")
                    } else {
                        initialized = true
                        play()
                    }
                }
            }
        } else if (initialized) play()
    }

    private fun play() {
        if (pending == null) return
        val tts = engine ?: return
        val locale = Locale.getDefault()
        val voice = tts.voices.orEmpty().filter {
            !it.isNetworkConnectionRequired &&
                !it.features.orEmpty().contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)
        }.sortedWith(compareByDescending<android.speech.tts.Voice> { it.locale == locale }
            .thenByDescending { it.locale.language == locale.language }
            .thenByDescending { it.locale.language == "en" }
            .thenByDescending { it.quality }).firstOrNull {
                it.locale.language == locale.language || it.locale.language == "en"
            }
        if (voice == null || tts.setVoice(voice) != TextToSpeech.SUCCESS) {
            finish(false, "Download an offline English or phone-language voice in Android text-to-speech settings, then ask again.")
            return
        }
        val id = (++utteranceId).toString()
        tts.setAudioAttributes(AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) { }
            override fun onDone(utteranceId: String?) {
                handler.post { if (utteranceId == id && id == this@LocalMessageSpeech.utteranceId.toString())
                    finish(true, "Message readout completed.") }
            }
            @Deprecated("Deprecated in Android")
            override fun onError(utteranceId: String?) {
                handler.post { if (utteranceId == id && id == this@LocalMessageSpeech.utteranceId.toString())
                    finish(false, "On-device message speech failed. Please try again.") }
            }
        })
        val params = Bundle().apply {
            @Suppress("DEPRECATION")
            putString(TextToSpeech.Engine.KEY_FEATURE_EMBEDDED_SYNTHESIS, "true")
        }
        if (tts.speak(text, TextToSpeech.QUEUE_FLUSH, params, id) != TextToSpeech.SUCCESS) {
            finish(false, "On-device message speech could not start.")
        }
    }

    private fun finish(success: Boolean, message: String) {
        val done = pending ?: return
        pending = null
        text = ""
        timeout?.let { handler.removeCallbacks(it) }
        timeout = null
        if (!success) {
            utteranceId++
            engine?.stop()
        }
        done(success, message)
    }

    fun stop() = finish(false, "Message reading stopped.")

    fun dispose() {
        stop()
        engine?.shutdown()
        engine = null
        initialized = false
    }
}
