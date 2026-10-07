package com.example.frontend

import android.accessibilityservice.AccessibilityService
import android.app.KeyguardManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/** Reads only visible Google Maps route summaries during an explicit user request. */
class MapsRouteReaderService : AccessibilityService() {
    companion object {
        const val MAPS_PACKAGE = "com.google.android.apps.maps"
        private var connected: MapsRouteReaderService? = null
        fun isConnected() = connected != null
        fun request(destination: String?, choice: Int?, detachedSpeech: Boolean, done: (Map<String, Any?>) -> Unit): Boolean {
            val service = connected ?: return false
            service.begin(destination, choice, detachedSpeech, done)
            return true
        }
        fun cancel(includeDetached: Boolean = false) {
            connected?.let { if (includeDetached || !it.detachedSpeech) it.finish(mapOf("success" to false, "message" to "Maps route reading stopped.")) }
        }
    }
    private val main = Handler(Looper.getMainLooper())
    private var pending: ((Map<String, Any?>) -> Unit)? = null
    private var destination: String? = null
    private var choice: Int? = null
    private var started = 0L
    private var stableSince = 0L
    private var signature = ""
    private var freshEvent = false
    private var detachedSpeech = false
    private val speech by lazy { LocalMessageSpeech(this) }
    private val poll = Runnable { inspect() }

    override fun onServiceConnected() { connected = this }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (pending != null && event?.packageName?.toString() == MAPS_PACKAGE) {
            freshEvent = true
        }
    }
    override fun onInterrupt() { finish(mapOf("success" to false, "message" to "Maps reading was interrupted.")) }
    override fun onDestroy() { finish(mapOf("success" to false, "message" to "Maps reader disconnected.")); speech.dispose(); if (connected === this) connected = null; super.onDestroy() }

    private fun begin(requested: String?, selectedChoice: Int?, speakDetached: Boolean, done: (Map<String, Any?>) -> Unit) {
        if (pending != null) { done(mapOf("success" to false, "message" to "A Maps route request is already running.")); return }
        pending = done; destination = requested; choice = selectedChoice
        detachedSpeech = speakDetached
        started = SystemClock.elapsedRealtime(); stableSince = 0L; signature = ""; freshEvent = requested == null
        main.postDelayed(poll, 600)
    }

    private fun inspect() {
        if (pending == null) return
        if (getSystemService(KeyguardManager::class.java).isDeviceLocked) {
            finish(mapOf("success" to false, "message" to "Unlock your phone to read the Maps route.")); return
        }
        val now = SystemClock.elapsedRealtime()
        if (now - started > 60_000) {
            val message = "Google Maps has not exposed a clear driving summary. Choose the destination and starting point, select Driving, then say Read the current Maps route. Maps stays open."
            val result = mapOf("success" to false, "status" to "needs_input", "opened" to (destination != null), "message" to message)
            if (detachedSpeech) speech.speak(message) { _, _ -> finish(result) } else finish(result)
            return
        }
        try {
            val root = mapsRoot()
            if (root != null) {
                var visited = 0
                fun snapshot(node: AccessibilityNodeInfo, depth: Int = 0): MapsTextNode {
                    if (++visited > 600 || depth > 25 || !node.isVisibleToUser) return MapsTextNode()
                    val text = listOf(node.text?.toString(), node.contentDescription?.toString()).filterNotNull().distinct().joinToString(" ").take(1500)
                    val children = (0 until node.childCount.coerceAtMost(80)).mapNotNull { node.getChild(it) }.map { snapshot(it, depth + 1) }
                    val routeGroup = Regex("route|directions.*summary", RegexOption.IGNORE_CASE).containsMatchIn(node.viewIdResourceName.orEmpty())
                    return MapsTextNode(text, node.isSelected || node.isChecked, children, routeGroup)
                }
                val tree = snapshot(root)
                val text = MapsRouteTextParser.text(tree)
                val loading = Regex("finding.*route|calculating|loading|updating route", RegexOption.IGNORE_CASE).containsMatchIn(text)
                val matching = destination == null || MapsRouteTextParser.matchesDestination(tree, destination!!)
                val driving = MapsRouteTextParser.isDriving(tree)
                if (freshEvent && matching && driving && !loading && now - started >= 3000) {
                    val routes = MapsRouteTextParser.routes(tree)
                    val next = routes.joinToString(";") { "${it.distanceMeters}:${it.durationSeconds}" }
                    if (next.isNotEmpty() && signature == next && now - stableSince >= 2000) {
                        val selected = choice
                        if (selected != null && selected !in 1..routes.size) {
                            finish(mapOf("success" to false, "status" to "needs_input", "message" to "That route choice is no longer visible. Ask me to read the current Maps route again.")); return
                        }
                        if (routes.size > 1 && selected == null) {
                            val result = mapOf("success" to true, "status" to "needs_input", "routes" to routes.map { it.toMap() })
                            if (detachedSpeech) {
                                speech.speak("Google Maps shows several driving routes. ${routes.mapIndexed { index, route -> "Route ${index + 1}: ${route.distanceText}, ${route.durationText}." }.joinToString(" ")} Select a route in Maps and ask me to read the current Maps route.") { success, message ->
                                    finish(if (success) result + ("spokenLocally" to true) else mapOf("success" to false, "message" to message))
                                }
                            } else finish(result)
                            return
                        }
                        val route = routes[(selected ?: 1) - 1]
                        val result = mapOf("success" to true, "status" to "completed", "route" to route.toMap(), "source" to "Google Maps app")
                        if (detachedSpeech) {
                            speech.speak("Google Maps shows ${route.distanceText} and ${route.durationText} by car for the displayed route. This is an estimate and can change.") { success, message ->
                                finish(if (success) result + ("spokenLocally" to true) else mapOf("success" to false, "message" to message))
                            }
                        } else finish(result)
                        return
                    }
                    if (signature != next) { signature = next; stableSince = now }
                } else { signature = ""; stableSince = 0L }
            } else { signature = ""; stableSince = 0L }
        } catch (_: Exception) { signature = ""; stableSince = 0L }
        main.postDelayed(poll, 600)
    }

    private fun mapsRoot(): AccessibilityNodeInfo? {
        val active = rootInActiveWindow
        if (active?.packageName?.toString() == MAPS_PACKAGE) return active
        // The assistant nudge can be above Maps. Only inspect content after its
        // root package matches Maps; discard every other application's root.
        return windows.asSequence().mapNotNull { it.root }.firstOrNull { it.packageName?.toString() == MAPS_PACKAGE && it.isVisibleToUser }
    }
    private fun finish(value: Map<String, Any?>) {
        main.removeCallbacks(poll)
        val done = pending; pending = null; destination = null; choice = null; signature = ""; stableSince = 0L
        if (value["success"] != true) speech.stop()
        detachedSpeech = false
        done?.invoke(value)
    }
}
