package com.example.frontend

import android.content.Context
import java.util.concurrent.CopyOnWriteArraySet

/**
 * One process-wide Vosk engine shared by Flutter and the selected Android
 * assistant service. Keeping a single owner prevents two AudioRecord instances
 * and two simultaneous model-unpack operations.
 */
object WakeWordRuntime {
    private val listeners =
        CopyOnWriteArraySet<(String, Map<String, Any?>) -> Unit>()

    @Volatile
    private var manager: VoskWakeWordManager? = null

    private fun manager(context: Context): VoskWakeWordManager {
        return manager ?: synchronized(this) {
            manager ?: VoskWakeWordManager(context.applicationContext) { method, arguments ->
                listeners.forEach { listener ->
                    try {
                        listener(method, arguments)
                    } catch (_: Exception) {
                        // A stale UI listener must never terminate wake detection.
                    }
                }
            }.also { manager = it }
        }
    }

    fun addListener(listener: (String, Map<String, Any?>) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (String, Map<String, Any?>) -> Unit) {
        listeners.remove(listener)
    }

    fun initialize(context: Context) {
        manager(context).initialize()
    }

    fun start(context: Context) {
        manager(context).start()
    }

    fun stop() {
        manager?.stop()
    }

    fun onMicrophonePermissionResult(context: Context, granted: Boolean) {
        manager(context).onMicrophonePermissionResult(granted)
    }
}
