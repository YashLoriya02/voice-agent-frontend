package com.example.frontend

data class CapturedMessage(
    val id: String,
    val notificationKey: String,
    val channel: String,
    val appName: String,
    val sender: String,
    val conversation: String,
    val body: String,
    val timestamp: Long,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "id" to id, "notificationKey" to notificationKey, "channel" to channel,
        "appName" to appName, "sender" to sender, "conversation" to conversation,
        "body" to body, "timestamp" to timestamp,
    )
}

/** Captured previews, not the source app's unread/read state. */
class MessageNotificationInbox(
    messages: List<CapturedMessage> = emptyList(),
    spoken: Map<String, Long> = emptyMap(),
    activeNotificationKeys: Set<String>? = null,
) {
    companion object {
        const val MAX_MESSAGES = 250
        const val RETENTION_MS = 24 * 60 * 60 * 1000L
    }

    private val entries = messages.associateByTo(linkedMapOf()) { it.id }
    private val heard = spoken.toMutableMap()
    private val active = (activeNotificationKeys ?: messages.map { it.notificationKey }.toSet()).toMutableSet()

    fun capture(messages: List<CapturedMessage>, now: Long) {
        messages.forEach { entries[it.id] = it; active.add(it.notificationKey) }
        prune(now)
    }

    fun removeNotification(key: String) {
        active.remove(key)
    }

    fun reconcile(activeKeys: Set<String>) {
        active.clear()
        active.addAll(entries.values.map { it.notificationKey }.filter { it in activeKeys })
    }

    fun acknowledge(ids: List<String>, now: Long) {
        ids.filter { it in entries }.forEach { heard[it] = now }
        prune(now)
    }

    fun messages(now: Long, unspokenOnly: Boolean = false): List<CapturedMessage> {
        prune(now)
        return entries.values.filter { !unspokenOnly || (it.id !in heard && it.notificationKey in active) }
            .sortedByDescending { it.timestamp }
    }

    fun spokenIds(now: Long): Map<String, Long> {
        prune(now)
        return heard.toMap()
    }

    fun activeNotificationKeys(now: Long): Set<String> {
        prune(now)
        return active.toSet()
    }

    private fun prune(now: Long) {
        entries.entries.removeAll { now - it.value.timestamp > RETENTION_MS }
        val retained = entries.values.sortedByDescending { it.timestamp }
            .take(MAX_MESSAGES).map { it.id }.toSet()
        entries.keys.retainAll(retained)
        active.retainAll(entries.values.map { it.notificationKey }.toSet())
        heard.entries.removeAll { now - it.value > RETENTION_MS }
        if (heard.size > MAX_MESSAGES * 2) {
            val newest = heard.entries.sortedByDescending { it.value }
                .take(MAX_MESSAGES * 2).map { it.key }.toSet()
            heard.keys.retainAll(newest)
        }
    }
}
