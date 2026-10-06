package com.example.frontend

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** App-private storage. Never included in Android backup or written to logs. */
object MessageNotificationStore {
    private const val PREFS = "message_notification_previews"
    private var inbox: MessageNotificationInbox? = null

    private fun load(context: Context): MessageNotificationInbox {
        inbox?.let { return it }
        val messages = mutableListOf<CapturedMessage>()
        val spoken = mutableMapOf<String, Long>()
        var activeKeys: Set<String>? = null
        try {
            val saved = JSONObject(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString("inbox", "{}") ?: "{}")
            val rows = saved.optJSONArray("messages") ?: JSONArray()
            for (i in 0 until rows.length()) {
                val row = rows.getJSONObject(i)
                messages.add(CapturedMessage(
                    row.getString("id"), row.getString("notificationKey"),
                    row.getString("channel"), row.getString("appName"),
                    row.getString("sender"), row.optString("conversation"),
                    row.getString("body"), row.getLong("timestamp"),
                ))
            }
            val ids = saved.optJSONObject("spoken") ?: JSONObject()
            ids.keys().forEach { spoken[it] = ids.getLong(it) }
            saved.optJSONArray("activeKeys")?.let { keys ->
                activeKeys = (0 until keys.length()).map { keys.getString(it) }.toSet()
            }
        } catch (_: Exception) {
            // A corrupt cache must not prevent notification access or startup.
            messages.clear()
            spoken.clear()
            activeKeys = emptySet()
        }
        return MessageNotificationInbox(messages, spoken, activeKeys).also { inbox = it }
    }

    private fun save(context: Context, state: MessageNotificationInbox) {
        val now = System.currentTimeMillis()
        val saved = JSONObject().put("messages", JSONArray(state.messages(now).map {
            JSONObject(it.toMap())
        })).put("spoken", JSONObject(state.spokenIds(now)))
            .put("activeKeys", JSONArray(state.activeNotificationKeys(now).toList()))
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("inbox", saved.toString()).apply()
    }

    @Synchronized fun capture(context: Context, messages: List<CapturedMessage>) {
        val state = load(context)
        state.capture(messages, System.currentTimeMillis())
        save(context, state)
    }

    @Synchronized fun remove(context: Context, key: String) {
        val state = load(context)
        state.removeNotification(key)
        save(context, state)
    }

    @Synchronized fun reconcile(context: Context, keys: Set<String>) {
        val state = load(context)
        state.reconcile(keys)
        save(context, state)
    }

    @Synchronized fun messages(context: Context, unspokenOnly: Boolean): List<CapturedMessage> {
        val state = load(context)
        val messages = state.messages(System.currentTimeMillis(), unspokenOnly)
        save(context, state)
        return messages
    }

    @Synchronized fun acknowledge(context: Context, ids: List<String>) {
        val state = load(context)
        state.acknowledge(ids, System.currentTimeMillis())
        save(context, state)
    }

    @Synchronized fun clear(context: Context) {
        inbox = MessageNotificationInbox()
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
    }
}
