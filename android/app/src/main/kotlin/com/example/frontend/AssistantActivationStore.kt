package com.example.frontend

import java.util.concurrent.atomic.AtomicBoolean

/** Carries one wake activation across the native assistant -> Flutter startup. */
object AssistantActivationStore {
    private val pending = AtomicBoolean(false)

    fun markPending() {
        pending.set(true)
    }

    fun consume(): Boolean = pending.getAndSet(false)
    fun clear() { pending.set(false) }
}
