package com.example.frontend

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.provider.Telephony
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import java.security.MessageDigest

class MessageNotificationListener : NotificationListenerService() {
    companion object {
        @Volatile private var active: MessageNotificationListener? = null
        val connected: Boolean get() = active != null

        fun synchronize(): Boolean {
            val listener = active ?: return false
            return listener.refresh()
        }

        fun rebind(context: Context) {
            requestRebind(ComponentName(context, MessageNotificationListener::class.java))
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        active = this
        refresh()
    }

    override fun onListenerDisconnected() {
        if (active === this) active = null
        super.onListenerDisconnected()
    }

    override fun onDestroy() {
        if (active === this) active = null
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        capture(sbn)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        MessageNotificationStore.remove(this, sbn.key)
    }

    private fun refresh(): Boolean = try {
        val notifications = activeNotifications ?: emptyArray()
        MessageNotificationStore.reconcile(this, notifications.map { it.key }.toSet())
        notifications.forEach(::capture)
        true
    } catch (_: Exception) {
        // A disconnected listener cannot make reliable claims about the inbox.
        false
    }

    @Suppress("DEPRECATION")
    private fun capture(sbn: StatusBarNotification) {
        try {
            val channel = when (sbn.packageName) {
                "com.whatsapp", "com.whatsapp.w4b" -> "whatsapp"
                "com.google.android.apps.messaging", "com.samsung.android.messaging",
                Telephony.Sms.getDefaultSmsPackage(this) -> "messages"
                else -> return
            }
            val notification = sbn.notification
            if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
            if (notification.category != Notification.CATEGORY_MESSAGE &&
                notification.extras.getParcelableArray(Notification.EXTRA_MESSAGES) == null) return
            val appName = when (sbn.packageName) {
                "com.whatsapp" -> "WhatsApp"
                "com.whatsapp.w4b" -> "WhatsApp Business"
                else -> "Messages"
            }
            val extras = notification.extras
            val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
            val conversation = extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)
                ?.toString()?.trim().orEmpty()
            val bundles = extras.getParcelableArray(Notification.EXTRA_MESSAGES)
            val rows = if (bundles != null && bundles.isNotEmpty()) {
                Notification.MessagingStyle.Message.getMessagesFromBundleArray(bundles)
                    .mapNotNull { message ->
                        val sender = if (Build.VERSION.SDK_INT >= 28) {
                            message.senderPerson?.name?.toString()
                        } else {
                            @Suppress("DEPRECATION")
                            message.sender?.toString()
                        }
                        // Null sender denotes the user's own outgoing message.
                        if (sender.isNullOrBlank()) null else preview(
                            sbn, channel, appName, sender, conversation,
                            message.text?.toString().orEmpty(),
                            message.timestamp.takeIf { it > 0 } ?: sbn.postTime,
                        )
                    }
            } else {
                val lines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
                val texts = if (!lines.isNullOrEmpty()) lines.map { it.toString() } else {
                    listOf((extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
                        ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty())
                }
                val timestamp = notification.`when`.takeIf { it > 0 } ?: sbn.postTime
                texts.mapNotNull { preview(sbn, channel, appName, title.ifBlank { "Unknown sender" },
                    conversation, it, timestamp) }
            }
            if (rows.isNotEmpty()) MessageNotificationStore.capture(this, rows)
        } catch (_: Exception) {
            // Third-party notifications can contain malformed or missing extras.
        }
    }

    private fun preview(
        sbn: StatusBarNotification, channel: String, appName: String,
        sender: String, conversation: String, text: String, timestamp: Long,
    ): CapturedMessage? {
        val body = text.trim().take(2000)
        if (body.isEmpty()) return null
        val identity = listOf(sbn.key, sender, conversation, body, timestamp.toString()).joinToString("\u0000")
        val id = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return CapturedMessage(id, sbn.key, channel, appName, sender.take(120),
            conversation.take(120), body, timestamp)
    }
}
