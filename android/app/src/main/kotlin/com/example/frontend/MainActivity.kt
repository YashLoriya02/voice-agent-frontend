package com.example.frontend

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.provider.AlarmClock
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.Manifest
import android.content.pm.PackageManager
import android.provider.ContactsContract
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.util.Locale

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.infiheal.voice_agent/actions"
    private val WAKE_WORD_CHANNEL = "com.infiheal.voice_agent/wake_word"

    private val CONTACTS_PERMISSION_REQUEST_CODE = 1001
    private val MICROPHONE_PERMISSION_REQUEST_CODE = 1002

    private var pendingContactsPermissionResult:
        MethodChannel.Result? = null

    private var wakeWordChannel: MethodChannel? = null
    private var wakeWordManager: VoskWakeWordManager? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        configureWakeWordChannel(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            try {

                when (call.method) {

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
        wakeWordManager?.dispose()
        wakeWordManager = VoskWakeWordManager(this) { method, arguments ->
            runOnUiThread {
                if (!isFinishing && !isDestroyed) {
                    channel.invokeMethod(method, arguments)
                }
            }
        }

        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "initialize" -> {
                        wakeWordManager?.initialize()
                        result.success(true)
                    }

                    "start" -> {
                        startWakeWordWithPermission()
                        result.success(true)
                    }

                    "stop" -> {
                        wakeWordManager?.stop()
                        result.success(true)
                    }

                    // Keep the unpacked model warm while this Activity lives.
                    // A later visit to the voice screen can therefore restart
                    // wake listening immediately.
                    "dispose" -> {
                        wakeWordManager?.stop()
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
            wakeWordManager?.start()
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

        wakeWordManager?.onMicrophonePermissionResult(granted)
    }
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

private fun normalizePhoneNumber(
    phoneNumber: String
): String {

    return phoneNumber
        .replace(" ", "")
        .replace("-", "")
        .replace("(", "")
        .replace(")", "")
}

override fun onDestroy() {
    wakeWordChannel?.setMethodCallHandler(null)
    wakeWordChannel = null
    wakeWordManager?.dispose()
    wakeWordManager = null
    super.onDestroy()
}
}
