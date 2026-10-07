package com.example.frontend

import android.app.Activity
import android.app.KeyguardManager
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.text.Html
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.ClearTokenRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.net.URL
import java.util.concurrent.Executors
import javax.net.ssl.HttpsURLConnection

/** OAuth tokens and mail travel only between this device and Google's Gmail API. */
class GmailBridge(private val activity: Activity) {
    companion object { const val AUTH_REQUEST = 1005 }
    private val client = Identity.getAuthorizationClient(activity)
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val speech = LocalMessageSpeech(activity)
    private var pending: MethodChannel.Result? = null
    private var arguments: Map<String, Any?> = emptyMap()
    private var connectOnly = false
    @Volatile private var generation = 0
    private var resolutionPending = false
    @Volatile private var connection: HttpsURLConnection? = null
    private var email = ""
    private var token: String? = null

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method !in setOf("gmailStatus", "connectGmail", "getGmailMessages",
                "disconnectGmail", "speakGmail", "stopGmailReadout")) return false
        when (call.method) {
            "gmailStatus" -> result.success(mapOf("success" to true, "connected" to email.isNotEmpty(), "email" to email))
            "stopGmailReadout" -> { cancel(); speech.stop(); result.success(mapOf("success" to true)) }
            "disconnectGmail" -> {
                cancel(); speech.stop(); email = ""
                token?.let { client.clearToken(ClearTokenRequest.builder().setToken(it).build()) }
                token = null
                result.success(mapOf("success" to true, "message" to "Gmail disconnected locally. Remove its access in your Google Account to revoke the grant."))
            }
            "speakGmail" -> {
                val text = call.argument<String>("text").orEmpty()
                if (locked()) result.success(failure("Unlock your phone before reading mail."))
                else if (text.isBlank() || text.length > 2000) result.success(failure("Mail readout is too long."))
                else speech.speak(text) { success, message -> result.success(mapOf("success" to success, "message" to message)) }
            }
            else -> {
                if (locked()) { result.success(failure("Unlock your phone before connecting or reading Gmail.")); return true }
                if (pending != null || resolutionPending) { result.success(failure("A Gmail request is already running. Finish or close Google consent first.")); return true }
                val limit = call.argument<Number>("limit")?.toInt() ?: 5
                val sender = call.argument<String>("sender").orEmpty().trim()
                if (limit !in 1..10 || sender.length > 120 || sender.any { it == '\n' || it == '\r' }) {
                    result.success(failure("Choose a mail limit from 1 to 10 and a valid sender.")); return true
                }
                arguments = mapOf("limit" to limit, "sender" to sender,
                    "unreadOnly" to (call.argument<Boolean>("unreadOnly") ?: true),
                    "countOnly" to (call.argument<Boolean>("countOnly") ?: false))
                connectOnly = call.method == "connectGmail"
                pending = result
                val current = ++generation
                client.authorize(AuthorizationRequest.builder().setRequestedScopes(
                    listOf(Scope("https://www.googleapis.com/auth/gmail.readonly"))).build())
                    .addOnSuccessListener { authorization ->
                        if (current != generation || pending == null) return@addOnSuccessListener
                        if (authorization.hasResolution()) {
                            resolutionPending = true
                            try { activity.startIntentSenderForResult(authorization.pendingIntent!!.intentSender,
                                AUTH_REQUEST, null, 0, 0, 0) }
                            catch (_: Exception) { resolutionPending = false; complete(failure("Could not open Google account consent. Try Connect Gmail again.")) }
                        } else fetchMail(authorization)
                    }.addOnFailureListener { if (current == generation) complete(failure(
                        "Gmail authorization failed. Enable Gmail API and register this app's package and signing SHA-1 in Google Cloud, then try again.")) }
            }
        }
        return true
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != AUTH_REQUEST) return
        resolutionPending = false
        if (pending == null) return
        if (resultCode != Activity.RESULT_OK || data == null) { complete(failure("Gmail connection was cancelled.")); return }
        try { fetchMail(client.getAuthorizationResultFromIntent(data)) }
        catch (_: Exception) { complete(failure("Google did not grant Gmail access. Try Connect Gmail again.")) }
    }

    private fun fetchMail(authorization: AuthorizationResult) {
        val accessToken = authorization.accessToken
        if (accessToken.isNullOrBlank()) { complete(failure("Google did not provide Gmail access.")); return }
        token = accessToken
        val current = generation
        val args = arguments
        val connecting = connectOnly
        val deadline = android.os.SystemClock.elapsedRealtime() + 45_000
        worker.execute {
            var account = ""
            val response = try {
                fun get(path: String): JSONObject {
                    if (current != generation) throw InterruptedException()
                    if (android.os.SystemClock.elapsedRealtime() > deadline) throw MailFailure("Gmail reading timed out. Try reading fewer emails.")
                    val http = URL("https://gmail.googleapis.com/gmail/v1/users/me/$path").openConnection() as HttpsURLConnection
                    connection = http
                    try {
                        http.connectTimeout = 12_000; http.readTimeout = 12_000
                        http.setRequestProperty("Authorization", "Bearer $accessToken")
                        if (http.responseCode == 401) {
                            client.clearToken(ClearTokenRequest.builder().setToken(accessToken).build())
                            throw MailFailure("Gmail access expired or was revoked. Please reconnect Gmail.")
                        }
                        if (http.responseCode != 200) throw MailFailure("Gmail could not be read. Check Gmail API setup, account access and your connection.")
                        return JSONObject(http.inputStream.bufferedReader().use { it.readText() })
                    } finally { http.disconnect(); if (connection === http) connection = null }
                }
                account = get("profile").getString("emailAddress")
                val unread = get("labels/INBOX").optInt("messagesUnread", 0)
                if (connecting) mapOf("success" to true, "connected" to true, "email" to account, "message" to "Gmail connected.")
                else if (args["countOnly"] == true) mapOf("success" to true, "unreadCount" to unread, "messages" to emptyList<Any>())
                else {
                    val sender = args["sender"] as String
                    val query = "in:inbox" + (if (args["unreadOnly"] == true) " is:unread" else "") +
                        (if (sender.isNotEmpty()) " from:\"${sender.replace("\\", "\\\\").replace("\"", "\\\"")}\"" else "")
                    val list = get("messages?maxResults=${args["limit"]}&q=${Uri.encode(query)}")
                    val ids = list.optJSONArray("messages")
                    val rows = (0 until (ids?.length() ?: 0)).map { index ->
                        val id = ids!!.getJSONObject(index).getString("id")
                        // Only headers and Gmail's preview snippet are fetched; no attachments or full MIME bodies.
                        val mail = get("messages/${Uri.encode(id)}?format=full&fields=id,snippet,payload/headers")
                        val headers = mail.optJSONObject("payload")?.optJSONArray("headers")
                        fun header(name: String): String = (0 until (headers?.length() ?: 0)).map { headers!!.getJSONObject(it) }
                            .firstOrNull { it.optString("name").equals(name, true) }?.optString("value").orEmpty().take(250)
                        @Suppress("DEPRECATION")
                        val snippet = Html.fromHtml(mail.optString("snippet")).toString().take(1000)
                        mapOf("id" to id, "sender" to header("From"), "subject" to header("Subject").ifBlank { "No subject" },
                            "body" to snippet.ifBlank { "No text preview available." }, "appName" to "Gmail")
                    }
                    mapOf("success" to true, "unreadCount" to unread, "messages" to rows,
                        "hasMore" to list.has("nextPageToken"))
                }
            } catch (e: MailFailure) { failure(e.message ?: "Gmail is unavailable.") }
              catch (_: Exception) { failure("Could not reach Gmail. Check your connection and try again.") }
            main.post { if (current == generation) {
                if (locked()) { complete(failure("Unlock your phone before reading mail.")); return@post }
                if (response["success"] == true) email = account
                complete(response)
            } }
        }
    }
    private fun locked() = activity.getSystemService(KeyguardManager::class.java).isDeviceLocked
    private fun complete(value: Map<String, Any?>) { val result = pending; pending = null; result?.success(value) }
    private fun cancel() { generation++; connection?.disconnect(); complete(failure("Gmail request stopped.")) }
    fun dispose() { cancel(); token = null; email = ""; speech.dispose(); worker.shutdownNow() }
    private fun failure(message: String): Map<String, Any?> = mapOf("success" to false, "message" to message)
    private class MailFailure(message: String): Exception(message)
}
