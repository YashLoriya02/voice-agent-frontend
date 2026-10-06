package com.example.frontend

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/** Phone actions stay local; only the result is returned to the voice provider. */
class DeviceControls(private val activity: Activity) {
    companion object { private const val CAMERA_REQUEST = 1004 }
    private var pendingTorch: Pair<Boolean, MethodChannel.Result>? = null

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method !in setOf("getLaunchableApps", "setTorch", "controlVolume", "setBrightness", "getBattery")) return false
        try {
            when (call.method) {
                "getLaunchableApps" -> {
                    val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                    @Suppress("DEPRECATION")
                    val apps = activity.packageManager.queryIntentActivities(intent, 0)
                        .map { mapOf("name" to it.loadLabel(activity.packageManager).toString(), "packageName" to it.activityInfo.packageName) }
                        .distinctBy { it["packageName"] }.sortedBy { it["name"] }
                    result.success(apps)
                }
                "setTorch" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: throw IllegalArgumentException("Specify torch on or off.")
                    if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                        if (pendingTorch != null) {
                            respond(result, false, "Please finish the camera permission request first.")
                        } else {
                            pendingTorch = enabled to result
                            ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.CAMERA), CAMERA_REQUEST)
                        }
                    } else setTorch(enabled, result)
                }
                "controlVolume" -> setVolume(call, result)
                "setBrightness" -> setBrightness(call, result)
                "getBattery" -> {
                    val battery = activity.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                    val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                    val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
                    if (level < 0 || scale <= 0) throw IllegalStateException("Battery status is unavailable.")
                    val percent = (100.0 * level / scale).roundToInt()
                    val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                    val suffix = when (status) {
                        BatteryManager.BATTERY_STATUS_CHARGING -> " and charging"
                        BatteryManager.BATTERY_STATUS_FULL -> " and fully charged"
                        else -> ""
                    }
                    respond(result, true, "Your battery is at $percent percent$suffix.")
                }
            }
        } catch (exception: Exception) {
            respond(result, false, exception.message ?: "I couldn't complete that device action.")
        }
        return true
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != CAMERA_REQUEST) return
        val pending = pendingTorch ?: return
        pendingTorch = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            try { setTorch(pending.first, pending.second) }
            catch (_: Exception) { respond(pending.second, false, "I couldn't change the torch. The camera may be in use.") }
        } else {
            respond(pending.second, false, "Camera permission is needed for the torch. Enable it in the app's permissions and try again.")
        }
    }

    fun dispose() {
        pendingTorch?.let { respond(it.second, false, "The torch request was cancelled.") }
        pendingTorch = null
    }

    private fun setTorch(enabled: Boolean, result: MethodChannel.Result) {
        val manager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameras = manager.cameraIdList.filter {
            manager.getCameraCharacteristics(it).get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        }
        val cameraId = cameras.firstOrNull {
            manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        } ?: cameras.firstOrNull() ?: throw IllegalStateException("This phone has no torch.")
        manager.setTorchMode(cameraId, enabled)
        respond(result, true, if (enabled) "Torch turned on." else "Torch turned off.")
    }

    private fun percent(call: MethodCall): Int {
        val value = (call.argument<Any>("percent") as? Number)?.toDouble()
            ?: throw IllegalArgumentException("Tell me a percentage from 0 to 100.")
        if (!value.isFinite() || value < 0 || value > 100) throw IllegalArgumentException("Choose a percentage from 0 to 100.")
        return value.roundToInt()
    }

    private fun setVolume(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("stream") ?: "media"
        val stream = when (name) {
            "media" -> AudioManager.STREAM_MUSIC
            "ring" -> AudioManager.STREAM_RING
            "alarm" -> AudioManager.STREAM_ALARM
            else -> throw IllegalArgumentException("Choose media, ring, or alarm volume.")
        }
        val audio = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val current = audio.getStreamVolume(stream)
        val max = audio.getStreamMaxVolume(stream)
        val min = if (Build.VERSION.SDK_INT >= 28) audio.getStreamMinVolume(stream) else 0
        val preferences = activity.getSharedPreferences("agent_device_controls", Context.MODE_PRIVATE)
        val operation = call.argument<String>("operation") ?: throw IllegalArgumentException("Tell me how to change the volume.")
        val target = when (operation) {
            "set" -> (max * percent(call) / 100.0).roundToInt()
            "increase" -> current + 1
            "decrease" -> current - 1
            "mute" -> 0
            "unmute" -> if (current > 0) current else preferences.getInt("volume_$name", (max / 2).coerceAtLeast(1))
            else -> throw IllegalArgumentException("That volume action is unavailable.")
        }.coerceIn(min, max)
        if (current > 0) preferences.edit().putInt("volume_$name", current).apply()
        if (operation == "unmute" || operation == "set") audio.adjustStreamVolume(stream, AudioManager.ADJUST_UNMUTE, 0)
        audio.setStreamVolume(stream, target, 0)
        val actual = audio.getStreamVolume(stream)
        val actualPercent = if (max > 0) (100.0 * actual / max).roundToInt() else 0
        respond(result, true, "${name.replaceFirstChar { it.uppercase() }} volume is at $actualPercent percent.")
    }

    private fun setBrightness(call: MethodCall, result: MethodChannel.Result) {
        val percent = percent(call)
        if (!Settings.System.canWrite(activity)) {
            activity.startActivity(Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:${activity.packageName}")))
            respond(result, false, "Allow modify system settings on the screen I opened, then ask me to change brightness again.")
            return
        }
        val resolver = activity.contentResolver
        val value = (255 * percent / 100.0).roundToInt().coerceIn(1, 255)
        val modeChanged = Settings.System.putInt(resolver, Settings.System.SCREEN_BRIGHTNESS_MODE, Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL)
        val valueChanged = Settings.System.putInt(resolver, Settings.System.SCREEN_BRIGHTNESS, value)
        if (!modeChanged || !valueChanged) throw IllegalStateException("I couldn't change system brightness.")
        respond(result, true, if (percent == 0) "Brightness set to minimum." else "Brightness set to $percent percent.")
    }

    private fun respond(result: MethodChannel.Result, success: Boolean, message: String) {
        result.success(mapOf("success" to success, "message" to message))
    }
}
