package com.example.frontend

import android.content.Context

object AssistantPreferences {
    private const val FILE_NAME = "hey_agent_preferences"
    private const val KEY_WAKE_ENABLED = "wake_enabled"
    private const val KEY_PROVIDER = "provider"

    fun isWakeEnabled(context: Context): Boolean {
        return context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_WAKE_ENABLED, true)
    }

    fun setWakeEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_WAKE_ENABLED, enabled)
            .apply()
    }

    fun preferredProvider(context: Context): String {
        return context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
            .getString(KEY_PROVIDER, "customGroq") ?: "customGroq"
    }

    fun setPreferredProvider(context: Context, provider: String) {
        context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_PROVIDER, provider)
            .apply()
    }
}
