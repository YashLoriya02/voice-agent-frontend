package com.example.frontend

import android.os.Bundle
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import java.lang.ref.WeakReference

/**
 * Runs the existing Flutter voice-agent stack without showing the full app.
 * The visible surface is owned by [AgentVoiceInteractionSession].
 */
class AssistantHostActivity : MainActivity() {
    companion object {
        private var activeActivity: WeakReference<AssistantHostActivity>? = null

        fun finishActive() {
            val activity = activeActivity?.get() ?: return
            activity.runOnUiThread {
                if (!activity.isFinishing && !activity.isDestroyed) {
                    activity.finish()
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        activeActivity = WeakReference(this)
    }

    override fun getInitialRoute(): String = "/assistant-background"

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    override fun getRenderMode(): RenderMode = RenderMode.texture

    override fun getTransparencyMode(): TransparencyMode =
        TransparencyMode.transparent

    override fun onDestroy() {
        if (activeActivity?.get() === this) {
            activeActivity = null
        }
        super.onDestroy()
    }
}
