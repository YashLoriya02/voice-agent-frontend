package com.example.frontend

/** Synthetic/testable representation of visible Maps accessibility nodes. */
data class MapsTextNode(val text: String = "", val selected: Boolean = false, val children: List<MapsTextNode> = emptyList(), val routeGroup: Boolean = false)
data class MapsDisplayedRoute(val distanceMeters: Double, val durationSeconds: Long, val distanceText: String, val durationText: String) {
    fun toMap(): Map<String, Any> = mapOf("distanceMeters" to distanceMeters, "durationSeconds" to durationSeconds,
        "distanceText" to distanceText, "durationText" to durationText)
}

object MapsRouteTextParser {
    private val duration = Regex("(?<![\\p{L}\\p{N}])(?:(\\d+)\\s*(?:days?|दिन)\\s*)?(?:(\\d+)\\s*(?:hours?|hrs?|h|घंटे?|घंटा)\\s*)?(?:(\\d+)\\s*(?:minutes?|mins?|min|मिनट))?(?![\\p{L}\\p{N}])", RegexOption.IGNORE_CASE)
    private val distance = Regex("(?<![\\p{L}\\p{N}.])([0-9]+(?:[.,][0-9]+)?)\\s*(kilomet(?:er|re)s?|km|miles?|mi|met(?:er|re)s?|m|किमी|मीटर)(?![\\p{L}\\p{N}])", RegexOption.IGNORE_CASE)
    private val range = Regex("\\d\\s*[–—-]\\s*\\d")
    private val driving = Regex("\\b(driving|drive|car)\\b|ड्राइविंग", RegexOption.IGNORE_CASE)

    fun isDriving(root: MapsTextNode): Boolean = (root.selected && driving.containsMatchIn(root.text)) ||
        (driving.containsMatchIn(root.text) && Regex("\\bselected\\b|चुना गया", RegexOption.IGNORE_CASE).containsMatchIn(root.text)) ||
        root.children.any { isDriving(it) }

    fun parse(text: String): MapsDisplayedRoute? {
        val normalized = text.replace('\u00a0', ' ').replace('\u202f', ' ').trim()
        if (normalized.isEmpty() || normalized.length > 2000 || range.containsMatchIn(normalized)) return null
        val times = duration.findAll(normalized).filter { match -> (1..3).any { match.groupValues[it].isNotEmpty() } }.toList()
        if (times.size != 1) return null
        val time = times.single()
        val distances = distance.findAll(normalized).filter { it.range.last < time.range.first || it.range.first > time.range.last }.toList()
        if (distances.size != 1) return null
        val length = distances.single()
        // Avoid interpreting unrelated screen text as one route summary.
        val between = if (time.range.last < length.range.first) normalized.substring(time.range.last + 1, length.range.first)
            else normalized.substring(length.range.last + 1, time.range.first)
        if (between.length > 80 || Regex("\\b(walk|walking|bus|transit|cycling|bicycle)\\b", RegexOption.IGNORE_CASE).containsMatchIn(normalized)) return null
        val seconds = try { time.groupValues[1].ifEmpty { "0" }.toLong() * 86400 +
            time.groupValues[2].ifEmpty { "0" }.toLong() * 3600 + time.groupValues[3].ifEmpty { "0" }.toLong() * 60 } catch (_: Exception) { return null }
        if (seconds !in 1..2_592_000) return null
        val rawNumber = length.groupValues[1]
        val number = (if (Regex("^\\d{1,3},\\d{3}$").matches(rawNumber)) rawNumber.replace(",", "") else rawNumber.replace(',', '.')).toDoubleOrNull() ?: return null
        val unit = length.groupValues[2].lowercase()
        val meters = number * when {
            unit.startsWith("km") || unit.startsWith("kilo") || unit == "किमी" -> 1000.0
            unit.startsWith("mi") -> 1609.344
            else -> 1.0
        }
        if (!meters.isFinite() || meters < 0 || meters > 40_000_000) return null
        return MapsDisplayedRoute(meters, seconds, length.value, time.value.trim())
    }

    /** Prefer the smallest node grouping containing one distance + one duration. */
    fun routes(root: MapsTextNode): List<MapsDisplayedRoute> {
        val found = mutableListOf<MapsDisplayedRoute>()
        fun visit(node: MapsTextNode): List<MapsDisplayedRoute> {
            val children = node.children.flatMap { visit(it) }
            val own = parse(node.text)
            if (own != null) return (children + own).distinctBy { it.distanceMeters to it.durationSeconds }
            if (children.isNotEmpty()) return children
            if (!node.routeGroup && !Regex("\\broutes?\\b", RegexOption.IGNORE_CASE).containsMatchIn(node.text)) return emptyList()
            val summary = (listOf(node.text) + node.children.map { it.text }).filter { it.isNotBlank() }.joinToString(" ")
            return listOfNotNull(parse(summary))
        }
        found.addAll(visit(root))
        return found.distinctBy { it.distanceMeters to it.durationSeconds }.take(3)
    }

    fun text(root: MapsTextNode): String = (listOf(root.text) + root.children.map { text(it) }).joinToString(" ").take(30_000)
    fun matchesDestination(root: MapsTextNode, requested: String): Boolean {
        val tokens = requested.lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.length >= 3 && it !in setOf("the", "from", "near", "to") }
        if (tokens.isEmpty()) return false
        val visible = text(root).lowercase().replace(Regex("[^\\p{L}\\p{N}]"), "")
        return tokens.all { visible.contains(it) }
    }
}
