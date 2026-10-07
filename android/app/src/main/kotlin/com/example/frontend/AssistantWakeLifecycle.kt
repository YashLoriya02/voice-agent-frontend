package com.example.frontend

/** Wake recording resumes only after both the panel and its voice host close. */
internal class AssistantWakeLifecycle {
    private var sessionVisible = false
    private var sessionGeneration = 0L
    private val hosts = mutableSetOf<Any>()

    val canListen: Boolean get() = !sessionVisible && hosts.isEmpty()

    fun sessionOpened(): Long {
        sessionVisible = true
        return ++sessionGeneration
    }

    fun sessionClosed(generation: Long): Boolean {
        if (!isCurrentSession(generation)) return false
        sessionVisible = false
        sessionGeneration++
        return true
    }

    fun isCurrentSession(generation: Long): Boolean =
        sessionVisible && generation == sessionGeneration

    fun hostOpened(host: Any) { hosts.add(host) }
    fun hostClosed(host: Any) { hosts.remove(host) }
}
