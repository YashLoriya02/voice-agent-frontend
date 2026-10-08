package com.example.frontend

import android.app.Activity
import android.app.KeyguardManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Opens the user's installed Maps app; no API keys, GPS collection or HTTP client. */
class InstalledMapsBridge(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private val speech = LocalMessageSpeech(activity)
    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method !in setOf("installedMapsStatus", "openMapsReaderSettings", "getInstalledMapsRoute", "stopInstalledMapsRoute", "speakInstalledMapsRoute")) return false
        when (call.method) {
            "installedMapsStatus" -> result.success(mapOf("success" to true, "installed" to installed(), "enabled" to enabled(), "connected" to MapsRouteReaderService.isConnected(),
                "message" to "Uses the installed Google Maps app. No Maps API key or billing setup is needed."))
            "openMapsReaderSettings" -> {
                try {
                    val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    activity.startActivity(intent)
                    result.success(mapOf("success" to true))
                } catch (_: Exception) {
                    try { activity.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)); result.success(mapOf("success" to true)) }
                    catch (_: Exception) { result.success(error("Open Android Accessibility settings and enable AI Voice Agent Maps reader.")) }
                }
            }
            "stopInstalledMapsRoute" -> { MapsRouteReaderService.cancel(call.argument<Boolean>("includeDetached") == true); speech.stop(); result.success(mapOf("success" to true)) }
            "speakInstalledMapsRoute" -> {
                val text = call.argument<String>("text").orEmpty()
                if (activity.getSystemService(KeyguardManager::class.java).isDeviceLocked) result.success(error("Unlock your phone before reading the Maps estimate."))
                else if (text.isBlank() || text.length > 2000) result.success(error("The Maps readout is invalid."))
                else speech.speak(text) { success, message -> result.success(mapOf("success" to success, "message" to message)) }
            }
            "getInstalledMapsRoute" -> {
                if (activity.getSystemService(KeyguardManager::class.java).isDeviceLocked) { result.success(error("Unlock your phone before opening or reading Maps.")); return true }
                if (!installed()) { result.success(error("Install Google Maps to use free driving estimates.")); return true }
                if (pending != null) { result.success(error("A Maps request is already running.")); return true }
                val readCurrent = call.argument<Boolean>("readCurrent") == true
                val startNavigation = call.argument<Boolean>("startNavigation") == true
                val destination = call.argument<String>("destination").orEmpty().trim()
                val choice = call.argument<Number>("choice")?.toInt()
                if (!readCurrent && (destination.isBlank() || destination.length > 250)) { result.success(error("Tell me the destination name and area or address.")); return true }
                if (choice != null && choice !in 1..3) { result.success(error("Choose a displayed route number from one to three.")); return true }
                if (startNavigation) {
                    if (readCurrent || choice != null) { result.success(error("Tell me a destination to start navigation.")); return true }
                    MapsRouteReaderService.cancel(includeDetached = true)
                    if (!openDirections(destination, startNavigation = true)) { result.success(error("Could not open Google Maps navigation.")); return true }
                    result.success(mapOf("success" to true, "status" to "opened", "message" to "Opening Google Maps navigation from your current location. Maps may ask you to choose a destination match or enable location."))
                    return true
                }
                val canRead = enabled() && MapsRouteReaderService.isConnected()
                if (!canRead) {
                    if (!readCurrent && !openDirections(destination)) { result.success(error("Could not open driving directions in Google Maps.")); return true }
                    result.success(mapOf("success" to true, "status" to "opened", "message" to "${if (readCurrent) "To read the current Maps route" else "Google Maps directions are open. To have the agent speak distance and time"}, enable AI Voice Agent Maps reader in Accessibility settings under Gmail & Maps. No Maps API billing is needed.")); return true
                }
                pending = result
                val started = MapsRouteReaderService.request(if (readCurrent) null else destination, choice, activity is AssistantHostActivity) { value ->
                    val waiting = pending; pending = null; waiting?.success(value)
                }
                if (!started) { pending = null; result.success(error("The Maps reader is connecting. Try again shortly.")); return true }
                if (!readCurrent && !openDirections(destination)) {
                    MapsRouteReaderService.cancel(includeDetached = true)
                }
            }
        }
        return true
    }
    private fun openDirections(destination: String, startNavigation: Boolean = false): Boolean = try {
        val uri = Uri.parse(InstalledMapsRequest.url(destination, startNavigation))
        activity.startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage(MapsRouteReaderService.MAPS_PACKAGE))
        (activity as? MainActivity)?.dismissAssistantAfterAppLaunch()
        true
    } catch (_: Exception) { false }
    private fun installed(): Boolean = try {
        @Suppress("DEPRECATION")
        activity.packageManager.getApplicationInfo(MapsRouteReaderService.MAPS_PACKAGE, 0).enabled
    } catch (_: PackageManager.NameNotFoundException) { false }
    private fun enabled(): Boolean {
        val target = ComponentName(activity, MapsRouteReaderService::class.java)
        return Settings.Secure.getString(activity.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
            .split(':').any { ComponentName.unflattenFromString(it) == target }
    }
    private fun error(message: String): Map<String, Any?> = mapOf("success" to false, "message" to message)
    fun dispose() {
        // A Hey Agent sheet closes when an external app opens. Its requested
        // readout continues in the Maps-only service using offline phone speech.
        if (pending != null && activity !is AssistantHostActivity) MapsRouteReaderService.cancel()
        pending = null
        speech.dispose()
    }
}
