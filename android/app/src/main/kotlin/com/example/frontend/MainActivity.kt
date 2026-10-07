package com.example.frontend

import android.content.ActivityNotFoundException
import android.content.Intent
import android.app.role.RoleManager
import android.os.Build
import android.os.Bundle
import android.net.Uri
import android.provider.AlarmClock
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.Manifest
import android.content.pm.PackageManager
import android.provider.ContactsContract
import android.provider.MediaStore
import android.telephony.PhoneNumberUtils
import android.telephony.TelephonyManager
import android.util.Log
import android.widget.Toast
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.util.Locale

open class MainActivity : FlutterActivity() {

    private val deviceControls by lazy { DeviceControls(this) }
    private val messageNotifications by lazy { MessageNotificationBridge(this) }
    private val gmail by lazy { GmailBridge(this) }
    private val installedMaps by lazy { InstalledMapsBridge(this) }

    companion object {
        private const val TAG = "HeyAgent/MainActivity"
    }

    private val CHANNEL = "com.infiheal.voice_agent/actions"
    private val WAKE_WORD_CHANNEL = "com.infiheal.voice_agent/wake_word"

    private val CONTACTS_PERMISSION_REQUEST_CODE = 1001
    private val MICROPHONE_PERMISSION_REQUEST_CODE = 1002
    private val ASSISTANT_ROLE_REQUEST_CODE = 1003

    private var pendingContactsPermissionResult:
        MethodChannel.Result? = null

    private var pendingAssistantRoleResult:
        MethodChannel.Result? = null

    private var wakeWordChannel: MethodChannel? = null
    private var assistantHostClosing = false
    private val assistantCloseHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val finishAssistantHost = Runnable { if (!isDestroyed) finish() }

    internal fun requestAssistantHostDismissal() {
        if (assistantHostClosing || isFinishing || isDestroyed) return
        assistantHostClosing = true
        // Ask Flutter to stop STT, local readout and provider audio before
        // destroying its engine. Re-arm wake recording after host teardown.
        assistantCloseHandler.postDelayed(finishAssistantHost, 2_500L)
        val channel = wakeWordChannel
        if (channel == null) {
            finishAssistantHost.run()
            return
        }
        channel.invokeMethod("dismiss", null, object : MethodChannel.Result {
            override fun success(result: Any?) { finishAssistantHost.run() }
            override fun error(code: String, message: String?, details: Any?) { finishAssistantHost.run() }
            override fun notImplemented() { finishAssistantHost.run() }
        })
    }

    private val wakeWordListener: (String, Map<String, Any?>) -> Unit =
        { method, arguments ->
            // The selected VoiceInteractionService owns the wake experience.
            // It speaks first and later sends a separate activation to Flutter.
            val handledBySystemAssistant =
                method == "detected" &&
                    AgentVoiceInteractionService.isSelected(this)

            if (!handledBySystemAssistant) {
                runOnUiThread {
                    val channel = wakeWordChannel
                    if (channel != null && !isFinishing && !isDestroyed) {
                        channel.invokeMethod(method, arguments)
                    }
                }
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureAssistantActivation(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureAssistantActivation(intent)
        dispatchPendingAssistantActivation()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        configureWakeWordChannel(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            if (deviceControls.handle(call, result)) return@setMethodCallHandler
            if (messageNotifications.handle(call, result)) return@setMethodCallHandler
            if (gmail.handle(call, result)) return@setMethodCallHandler
            if (installedMaps.handle(call, result)) return@setMethodCallHandler

            try {

                when (call.method) {

                    "closeAssistant" -> {
                        result.success(true)
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            AgentVoiceInteractionSession.dismissActiveSession()
                            if (this is AssistantHostActivity) finish() else finishAndRemoveTask()
                        }
                    }

                    "requestContactsPermission" -> {
                        requestContactsPermission(result)
                    }

                    "findContacts" -> {

                        val query =
                            call.argument<String>("query")

                        if (query.isNullOrBlank()) {

                            result.error(
                                "INVALID_ARGUMENT",
                                "Contact name is required.",
                                null
                            )

                            return@setMethodCallHandler
                        }

                        val contacts = findContacts(query)

                        result.success(contacts)
                    }

                    "setAlarm" -> {

                        val hour = call.argument<Int>("hour")
                        val minute = call.argument<Int>("minute")
                        val label =
                            call.argument<String>("label") ?: "Healo Alarm"

                        if (hour == null || minute == null) {
                            result.error(
                                "INVALID_ARGUMENT",
                                "Hour and minute are required.",
                                null
                            )
                            return@setMethodCallHandler
                        }

                        setAlarm(
                            hour = hour,
                            minute = minute,
                            label = label
                        )

                        result.success(true)
                    }

                    "setTimer" -> {

                        val seconds = call.argument<Int>("seconds")
                        val label =
                            call.argument<String>("label") ?: "Healo Timer"

                        if (seconds == null || seconds <= 0) {
                            result.error(
                                "INVALID_ARGUMENT",
                                "Timer duration must be greater than zero.",
                                null
                            )
                            return@setMethodCallHandler
                        }

                        setTimer(
                            seconds = seconds,
                            label = label
                        )

                        result.success(true)
                    }

                    "openApp" -> {

                        val packageName =
                            call.argument<String>("packageName")

                        if (packageName.isNullOrBlank()) {
                            result.error(
                                "INVALID_ARGUMENT",
                                "Package name is required.",
                                null
                            )
                            return@setMethodCallHandler
                        }

                        val opened = openApp(packageName)

                        if (opened) {
                            result.success(true)
                        } else {
                            result.error(
                                "APP_NOT_FOUND",
                                "Application is not installed.",
                                packageName
                            )
                        }
                    }

                    "openAppTarget" -> {
                        val packageNames =
                            call.argument<List<String>>("packageNames") ?: emptyList()
                        val systemTarget = call.argument<String>("systemTarget")

                        if (openAppTarget(packageNames, systemTarget)) {
                            result.success(true)
                        } else {
                            result.error(
                                "APP_NOT_FOUND",
                                "No compatible application is installed.",
                                systemTarget,
                            )
                        }
                    }

                    "openAgentApp" -> {
                        openVisibleAgentApp()
                        result.success(true)
                    }

                    "composeMessage" -> {
                        val phoneNumber = call.argument<String>("phoneNumber")
                        val message = call.argument<String>("message")
                        val channel = call.argument<String>("channel")

                        if (phoneNumber.isNullOrBlank() || message.isNullOrBlank()) {
                            result.error(
                                "INVALID_ARGUMENT",
                                "A phone number and message are required.",
                                null,
                            )
                            return@setMethodCallHandler
                        }

                        result.success(
                            composeMessage(
                                phoneNumber = phoneNumber,
                                message = message,
                                preferredChannel = channel ?: "messages",
                            ),
                        )
                    }

                    "isWhatsAppAvailable" -> {
                        result.success(
                            listOf("com.whatsapp", "com.whatsapp.w4b").any {
                                packageManager.getLaunchIntentForPackage(it) != null
                            },
                        )
                    }

                    "dialNumber" -> {

                        val phoneNumber =
                            call.argument<String>("phoneNumber")

                        if (phoneNumber.isNullOrBlank()) {
                            result.error(
                                "INVALID_ARGUMENT",
                                "Phone number is required.",
                                null
                            )
                            return@setMethodCallHandler
                        }

                        dialNumber(phoneNumber)

                        result.success(true)
                    }

                    else -> {
                        result.notImplemented()
                    }
                }

            } catch (exception: ActivityNotFoundException) {

    result.error(
        "APP_NOT_AVAILABLE",
        exception.message,
        null
    )

} catch (exception: SecurityException) {

    result.error(
        "PERMISSION_DENIED",
        exception.message,
        null
    )

} catch (exception: Exception) {

    result.error(
        "ACTION_FAILED",
        exception.message ?: "Unknown error",
        null
    )
}
        }
    }

    private fun configureWakeWordChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WAKE_WORD_CHANNEL,
        )

        wakeWordChannel = channel
        WakeWordRuntime.removeListener(wakeWordListener)
        WakeWordRuntime.addListener(wakeWordListener)

        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "initialize" -> {
                        WakeWordRuntime.initialize(this)
                        result.success(true)
                    }

                    "start" -> {
                        startWakeWordWithPermission()
                        result.success(true)
                    }

                    "stop" -> {
                        if (!assistantHostClosing && !isFinishing && !isDestroyed) {
                            WakeWordRuntime.stop()
                        }
                        result.success(true)
                    }

                    "setEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        AssistantPreferences.setWakeEnabled(this, enabled)
                        if (enabled) {
                            startWakeWordWithPermission()
                        } else {
                            WakeWordRuntime.stop()
                        }
                        result.success(true)
                    }

                    "assistantStatus" -> {
                        result.success(
                            mapOf(
                                "selected" to isAssistantRoleHeld(),
                                "wakeEnabled" to AssistantPreferences.isWakeEnabled(this),
                            ),
                        )
                    }

                    "getPreferredProvider" -> {
                        result.success(AssistantPreferences.preferredProvider(this))
                    }

                    "setPreferredProvider" -> {
                        val provider =
                            call.argument<String>("provider") ?: "customGroq"
                        AssistantPreferences.setPreferredProvider(this, provider)
                        result.success(true)
                    }

                    "requestAssistantRole" -> {
                        requestAssistantRole(result)
                    }

                    "previewAssistantUi" -> {
                        startActivity(
                            Intent(this, AssistantPreviewActivity::class.java),
                        )
                        result.success(true)
                    }

                    "updateAssistantUi" -> {
                        AgentVoiceInteractionSession.updateActiveState(
                            call.argument<String>("phase").orEmpty(),
                            call.argument<String>("caption").orEmpty(),
                        )
                        result.success(null)
                    }

                    "consumePendingActivation" -> {
                        result.success(AssistantActivationStore.consume())
                    }

                    "backgroundHandoff" -> {
                        val canListen = call.argument<Boolean>("canListen") ?: false
                        if (
                            canListen &&
                            isAssistantRoleHeld() &&
                            AssistantPreferences.isWakeEnabled(this)
                        ) {
                            AgentVoiceInteractionService.startSelectedListener(this)
                            WakeWordRuntime.start(this)
                        } else if (!canListen && !assistantHostClosing && !isFinishing && !isDestroyed) {
                            WakeWordRuntime.stop()
                        }
                        result.success(true)
                    }

                    // Keep the unpacked model warm while this Activity lives.
                    // A later visit to the voice screen can therefore restart
                    // wake listening immediately.
                    "dispose" -> {
                        if (
                            isAssistantRoleHeld() &&
                            AssistantPreferences.isWakeEnabled(this)
                        ) {
                            AgentVoiceInteractionService.scheduleSelectedListener(this)
                        } else {
                            WakeWordRuntime.stop()
                        }
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            } catch (exception: Exception) {
                result.error(
                    "WAKE_WORD_ERROR",
                    exception.message ?: "Wake-word operation failed.",
                    null,
                )
            }
        }
    }

    private fun startWakeWordWithPermission() {
        if (
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.RECORD_AUDIO,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            WakeWordRuntime.start(this)
            return
        }

        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            MICROPHONE_PERMISSION_REQUEST_CODE,
        )
    }

    private fun setAlarm(
    hour: Int,
    minute: Int,
    label: String
) {
    val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
        putExtra(AlarmClock.EXTRA_HOUR, hour)
        putExtra(AlarmClock.EXTRA_MINUTES, minute)
        putExtra(AlarmClock.EXTRA_MESSAGE, label)
    }

    try {
        startActivity(intent)
    } catch (e: ActivityNotFoundException) {
        throw ActivityNotFoundException(
            "No Clock/Alarm application is available on this device."
        )
    }
}

    private fun setTimer(
    seconds: Int,
    label: String
) {
    val intent = Intent(AlarmClock.ACTION_SET_TIMER).apply {
        putExtra(AlarmClock.EXTRA_LENGTH, seconds)
        putExtra(AlarmClock.EXTRA_MESSAGE, label)

        // Keep false while debugging.
        // We'll enable true later.
        putExtra(AlarmClock.EXTRA_SKIP_UI, false)
    }

    try {
        startActivity(intent)
    } catch (e: ActivityNotFoundException) {
        throw ActivityNotFoundException(
            "No Clock/Timer application is available on this device."
        )
    }
}

    private fun openApp(
        packageName: String
    ): Boolean {

        val launchIntent =
            packageManager.getLaunchIntentForPackage(packageName)
                ?: return false

        startActivity(launchIntent)

        return true
    }

    private fun openAppTarget(
        packageNames: List<String>,
        systemTarget: String?,
    ): Boolean {
        if (systemTarget == "agent") {
            openVisibleAgentApp()
            return true
        }

        for (packageName in packageNames.distinct()) {
            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            if (launchIntent != null && tryStartActivity(launchIntent)) {
                return true
            }
        }

        val fallbackIntents = when (systemTarget) {
            "messages" -> listOf(
                Intent(Intent.ACTION_MAIN).addCategory(
                    "android.intent.category.APP_MESSAGING",
                ),
                Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:")),
            )

            "gallery" -> listOf(
                Intent(Intent.ACTION_MAIN).addCategory(
                    "android.intent.category.APP_GALLERY",
                ),
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                        "image/*",
                    )
                },
            )

            "settings" -> listOf(Intent(Settings.ACTION_SETTINGS))

            "camera" -> listOf(
                Intent(MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA),
                Intent(MediaStore.ACTION_IMAGE_CAPTURE),
            )

            "email" -> listOf(
                Intent(Intent.ACTION_MAIN).addCategory(
                    "android.intent.category.APP_EMAIL",
                ),
            )

            "maps" -> listOf(
                Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0")),
            )

            else -> emptyList()
        }

        return fallbackIntents.any(::tryStartActivity)
    }

    private fun openVisibleAgentApp() {
        AgentVoiceInteractionSession.dismissActiveSession()

        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        }

        startActivity(intent)

        if (this is AssistantHostActivity) {
            finish()
        }
    }

    private fun composeMessage(
        phoneNumber: String,
        message: String,
        preferredChannel: String,
    ): String {
        if (
            preferredChannel.equals("whatsapp", ignoreCase = true) &&
            openWhatsAppComposer(phoneNumber, message)
        ) {
            return "whatsapp"
        }

        val smsIntent = Intent(
            Intent.ACTION_SENDTO,
            Uri.fromParts("smsto", phoneNumber, null),
        ).apply {
            putExtra("sms_body", message)
        }

        if (!tryStartActivity(smsIntent)) {
            throw ActivityNotFoundException(
                "No compatible messaging application is installed.",
            )
        }

        return "messages"
    }

    private fun openWhatsAppComposer(
        phoneNumber: String,
        message: String,
    ): Boolean {
        val normalizedNumber = normalizeForWhatsApp(phoneNumber)
        if (normalizedNumber.isBlank()) return false

        val uri = Uri.parse("https://wa.me/$normalizedNumber")
            .buildUpon()
            .appendQueryParameter("text", message)
            .build()

        return listOf("com.whatsapp", "com.whatsapp.w4b").any { packageName ->
            tryStartActivity(
                Intent(Intent.ACTION_VIEW, uri).setPackage(packageName),
            )
        }
    }

    private fun normalizeForWhatsApp(phoneNumber: String): String {
        val telephonyManager =
            getSystemService(android.content.Context.TELEPHONY_SERVICE) as?
                TelephonyManager
        val countryCode = sequenceOf(
            telephonyManager?.simCountryIso,
            telephonyManager?.networkCountryIso,
            Locale.getDefault().country,
        ).firstOrNull { !it.isNullOrBlank() }

        val e164 = if (countryCode.isNullOrBlank()) {
            null
        } else {
            PhoneNumberUtils.formatNumberToE164(
                phoneNumber,
                countryCode.uppercase(Locale.US),
            )
        }

        return (e164 ?: PhoneNumberUtils.normalizeNumber(phoneNumber))
            .removePrefix("+")
    }

    private fun tryStartActivity(intent: Intent): Boolean {
        return try {
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    private fun dialNumber(
    phoneNumber: String
) {
    val intent = Intent(
        Intent.ACTION_DIAL,
        Uri.parse("tel:${Uri.encode(phoneNumber)}")
    )

    try {
        startActivity(intent)
    } catch (e: ActivityNotFoundException) {
        throw ActivityNotFoundException(
            "No dialer application is available on this device."
        )
    }
}

private fun requestContactsPermission(
    result: MethodChannel.Result
) {

    val permission =
        Manifest.permission.READ_CONTACTS

    if (
        ContextCompat.checkSelfPermission(
            this,
            permission
        ) == PackageManager.PERMISSION_GRANTED
    ) {

        result.success(true)
        return
    }

    pendingContactsPermissionResult = result

    ActivityCompat.requestPermissions(
        this,
        arrayOf(permission),
        CONTACTS_PERMISSION_REQUEST_CODE
    )
}

override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<out String>,
    grantResults: IntArray
) {

    super.onRequestPermissionsResult(
        requestCode,
        permissions,
        grantResults
    )

    deviceControls.onPermissionResult(requestCode, grantResults)

    if (
        requestCode ==
        CONTACTS_PERMISSION_REQUEST_CODE
    ) {

        val granted =
            grantResults.isNotEmpty() &&
            grantResults[0] ==
            PackageManager.PERMISSION_GRANTED

        pendingContactsPermissionResult
            ?.success(granted)

        pendingContactsPermissionResult = null
    }

    if (requestCode == MICROPHONE_PERMISSION_REQUEST_CODE) {
        val granted =
            grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED

        WakeWordRuntime.onMicrophonePermissionResult(this, granted)
    }
}

override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    super.onActivityResult(requestCode, resultCode, data)
    gmail.onActivityResult(requestCode, resultCode, data)

    if (requestCode == ASSISTANT_ROLE_REQUEST_CODE) {
        val selected = isAssistantRoleHeld()
        pendingAssistantRoleResult?.success(selected)
        pendingAssistantRoleResult = null

        if (selected && AssistantPreferences.isWakeEnabled(this)) {
            startWakeWordWithPermission()
        }
    }
}

private fun isAssistantRoleHeld(): Boolean {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        val roleManager = getSystemService(RoleManager::class.java)
        if (
            roleManager.isRoleAvailable(RoleManager.ROLE_ASSISTANT) &&
            roleManager.isRoleHeld(RoleManager.ROLE_ASSISTANT)
        ) {
            return true
        }
    }

    return AgentVoiceInteractionService.isSelected(this)
}

private fun requestAssistantRole(result: MethodChannel.Result) {
    Log.i(TAG, "Assistant role requested from Flutter.")

    if (isAssistantRoleHeld()) {
        Toast.makeText(this, "AI Voice Agent is already the default assistant.", Toast.LENGTH_SHORT).show()
        result.success(true)
        return
    }

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        val roleManager = getSystemService(RoleManager::class.java)
        if (roleManager.isRoleAvailable(RoleManager.ROLE_ASSISTANT)) {
            try {
                val roleIntent =
                    roleManager.createRequestRoleIntent(RoleManager.ROLE_ASSISTANT)

                if (roleIntent.resolveActivity(packageManager) != null) {
                    pendingAssistantRoleResult?.error(
                        "REQUEST_REPLACED",
                        "A newer assistant-role request replaced this request.",
                        null,
                    )
                    pendingAssistantRoleResult = result
                    Toast.makeText(
                        this,
                        "Choose AI Voice Agent as the default assistant.",
                        Toast.LENGTH_LONG,
                    ).show()
                    startActivityForResult(
                        roleIntent,
                        ASSISTANT_ROLE_REQUEST_CODE,
                    )
                    return
                }

                Log.w(TAG, "Assistant role intent has no matching system activity.")
            } catch (exception: Exception) {
                Log.w(TAG, "Assistant role dialog failed; opening Settings.", exception)
            }
        } else {
            Log.w(TAG, "ROLE_ASSISTANT is unavailable; opening Settings.")
        }
    }

    openAssistantSettings(result)
}

private fun openAssistantSettings(result: MethodChannel.Result) {
    val candidates = listOf(
        Intent(Settings.ACTION_VOICE_INPUT_SETTINGS),
        Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS),
        Intent(Settings.ACTION_SETTINGS),
    )

    val settingsIntent = candidates.firstOrNull {
        it.resolveActivity(packageManager) != null
    }

    if (settingsIntent == null) {
        result.error(
            "ASSISTANT_SETTINGS_UNAVAILABLE",
            "Android could not open Default Assistant settings.",
            null,
        )
        return
    }

    Toast.makeText(
        this,
        "Open Digital assistant app and select AI Voice Agent.",
        Toast.LENGTH_LONG,
    ).show()
    startActivity(settingsIntent)
    result.success(false)
}

private fun captureAssistantActivation(intent: Intent?) {
    if (
        intent?.getBooleanExtra(
            AgentVoiceInteractionService.EXTRA_WAKE_ACTIVATION,
            false,
        ) == true
    ) {
        AssistantActivationStore.markPending()
        intent.removeExtra(AgentVoiceInteractionService.EXTRA_WAKE_ACTIVATION)
    }
}

private fun dispatchPendingAssistantActivation() {
    if (wakeWordChannel == null) return
    if (!AssistantActivationStore.consume()) return
    wakeWordChannel?.invokeMethod(
        "activation",
        mapOf("source" to "system_assistant"),
    )
}

private fun findContacts(
    query: String
): List<Map<String, Any?>> {

    if (
        ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.READ_CONTACTS
        ) != PackageManager.PERMISSION_GRANTED
    ) {
        throw SecurityException(
            "Contacts permission not granted."
        )
    }

    val normalizedQuery =
        normalizeContactName(query)

    if (normalizedQuery.isBlank()) {
        return emptyList()
    }

    val results =
        mutableListOf<
            Pair<Int, Map<String, Any?>>
        >()

    val projection =
        arrayOf(
            ContactsContract
                .CommonDataKinds
                .Phone
                .CONTACT_ID,

            ContactsContract
                .CommonDataKinds
                .Phone
                .DISPLAY_NAME,

            ContactsContract
                .CommonDataKinds
                .Phone
                .NUMBER,

            ContactsContract
                .CommonDataKinds
                .Phone
                .TYPE,

            ContactsContract
                .CommonDataKinds
                .Phone
                .LABEL
        )

    val cursor =
        contentResolver.query(
            ContactsContract
                .CommonDataKinds
                .Phone
                .CONTENT_URI,

            projection,

            null,
            null,
            null
        )

    cursor?.use {

        val idIndex =
            it.getColumnIndexOrThrow(
                ContactsContract
                    .CommonDataKinds
                    .Phone
                    .CONTACT_ID
            )

        val nameIndex =
            it.getColumnIndexOrThrow(
                ContactsContract
                    .CommonDataKinds
                    .Phone
                    .DISPLAY_NAME
            )

        val numberIndex =
            it.getColumnIndexOrThrow(
                ContactsContract
                    .CommonDataKinds
                    .Phone
                    .NUMBER
            )

        val typeIndex =
            it.getColumnIndexOrThrow(
                ContactsContract
                    .CommonDataKinds
                    .Phone
                    .TYPE
            )

        val labelIndex =
            it.getColumnIndexOrThrow(
                ContactsContract
                    .CommonDataKinds
                    .Phone
                    .LABEL
            )

        while (
            it.moveToNext()
        ) {
            val name =
                it.getString(nameIndex)
                    ?: ""

            val normalizedName =
                normalizeContactName(
                    name
                )

            /*
             * Ranking:
             *
             * 0 = exact normalized match
             * 1 = begins with query
             * 2 = contains query
             */
            val score =
                when {

                    normalizedName ==
                        normalizedQuery -> 0

                    normalizedName
                        .startsWith(
                            normalizedQuery
                        ) -> 1

                    normalizedName
                        .contains(
                            normalizedQuery
                        ) -> 2

                    else -> -1
                }

            if (score == -1) {
                continue
            }

            val id =
                it.getLong(
                    idIndex
                )

            val number =
                it.getString(
                    numberIndex
                ) ?: ""

            val type =
                it.getInt(
                    typeIndex
                )

            val customLabel =
                it.getString(
                    labelIndex
                )

            val phoneLabel =
                ContactsContract
                    .CommonDataKinds
                    .Phone
                    .getTypeLabel(
                        resources,
                        type,
                        customLabel
                    )
                    .toString()

            results.add(
                score to
                    mapOf(
                        "id" to
                            id.toString(),

                        "name" to
                            name,

                        "phoneNumber" to
                            number,

                        "label" to
                            phoneLabel
                    )
            )
        }
    }

    return results
        .sortedBy {
            it.first
        }
        .map {
            it.second
        }
        .distinctBy {

            (
                it["phoneNumber"]
                    ?.toString()
                    ?: ""
            )
                .filter {
                    char ->
                    char.isDigit()
                }
        }
        .take(20)
}

private fun normalizeContactName(
    value: String
): String {

    return value
        .lowercase(Locale.ROOT)
        .replace(
            Regex("[^\\p{L}\\p{N}]"),
            ""
        )
}

override fun onDestroy() {
    assistantHostClosing = true
    assistantCloseHandler.removeCallbacksAndMessages(null)
    installedMaps.dispose()
    gmail.dispose()
    messageNotifications.dispose()
    deviceControls.dispose()
    wakeWordChannel?.setMethodCallHandler(null)
    wakeWordChannel = null
    WakeWordRuntime.removeListener(wakeWordListener)

    super.onDestroy()
    if (
        isAssistantRoleHeld() &&
        AssistantPreferences.isWakeEnabled(this)
    ) {
        AgentVoiceInteractionService.scheduleSelectedListener(this)
    } else {
        WakeWordRuntime.stop()
    }
}
}
