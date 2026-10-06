package com.example.frontend

import android.app.Activity
import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MessageNotificationBridge(private val activity: Activity) {
    private val speech = LocalMessageSpeech(activity)
    fun dispose() = speech.dispose()
    private fun enabled(): Boolean {
        val component = ComponentName(activity, MessageNotificationListener::class.java)
        return if (Build.VERSION.SDK_INT >= 27) {
            activity.getSystemService(NotificationManager::class.java)
                .isNotificationListenerAccessGranted(component)
        } else {
            Settings.Secure.getString(activity.contentResolver, "enabled_notification_listeners")
                ?.split(':')?.any { ComponentName.unflattenFromString(it) == component } == true
        }
    }

    private fun openSettings() {
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                activity.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                    .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                        ComponentName(activity, MessageNotificationListener::class.java).flattenToString()))
                return
            } catch (_: Exception) { }
        }
        activity.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
    }

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method !in setOf("messageNotificationStatus", "openMessageNotificationSettings",
                "getMessageNotifications", "speakMessageNotifications", "stopMessageReadout")) return false
        try {
            when (call.method) {
                "messageNotificationStatus" -> {
                    val access = enabled()
                    if (!access) MessageNotificationStore.clear(activity)
                    result.success(mapOf("enabled" to access,
                        "connected" to (access && MessageNotificationListener.connected)))
                }
                "openMessageNotificationSettings" -> {
                    openSettings()
                    result.success(mapOf("success" to true))
                }
                "getMessageNotifications" -> {
                    if (!enabled()) {
                        MessageNotificationStore.clear(activity)
                        openSettings()
                        result.success(mapOf("success" to false, "message" to
                            "Enable notification access for AI Voice Agent on this settings screen, then ask again."))
                    } else if ((activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isDeviceLocked) {
                        result.success(mapOf("success" to false, "message" to
                            "Unlock your phone before reading message notifications."))
                    } else if (!MessageNotificationListener.synchronize() && call.argument<Boolean>("includeHistory") != true) {
                        MessageNotificationListener.rebind(activity)
                        result.success(mapOf("success" to false, "message" to
                            "Message notification access is still connecting. Please try again in a moment."))
                    } else {
                        result.success(mapOf("success" to true, "messages" to
                            MessageNotificationStore.messages(activity, false).map { it.toMap() },
                            "unspokenIds" to MessageNotificationStore.messages(activity, true).map { it.id }))
                    }
                }
                "speakMessageNotifications" -> {
                    val text = call.argument<String>("text").orEmpty()
                    val ids = call.argument<List<String>>("ids") ?: emptyList()
                    if (!enabled() || (activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isDeviceLocked) {
                        result.success(mapOf("success" to false, "message" to "Unlock the phone and enable message notification access, then ask again."))
                    } else if (text.isBlank() || text.length > 2000 || ids.size > 10) {
                        result.success(mapOf("success" to false, "message" to "The message readout is too long. Ask to read fewer messages."))
                    } else speech.speak(text) { success, message ->
                        if (success && enabled()) MessageNotificationStore.acknowledge(activity, ids)
                        result.success(mapOf("success" to success, "message" to message))
                    }
                }
                "stopMessageReadout" -> {
                    speech.stop()
                    result.success(mapOf("success" to true))
                }
            }
        } catch (_: Exception) {
            result.error("MESSAGE_NOTIFICATIONS_FAILED", "Message notification access is unavailable.", null)
        }
        return true
    }
}
