package com.example.frontend

import org.junit.Assert.*
import org.junit.Test

class AssistantWakeLifecycleTest {
    @Test fun repeatedSessionsResumeWakeOnlyAfterVoiceHostTeardown() {
        val state = AssistantWakeLifecycle()
        repeat(5) {
            val session = state.sessionOpened()
            val host = Any()
            state.hostOpened(host)
            assertFalse(state.canListen)
            state.sessionClosed(session)
            // Closing the panel alone must not steal the provider microphone.
            assertFalse(state.canListen)
            state.hostClosed(host)
            assertTrue(state.canListen)
        }
    }

    @Test fun closeDuringGreetingRearmsWithoutEverStartingFlutter() {
        val state = AssistantWakeLifecycle()
        val greeting = state.sessionOpened()
        state.sessionClosed(greeting)
        assertTrue(state.canListen)
        assertFalse(state.isCurrentSession(greeting))
    }

    @Test fun lateGreetingAndOldSessionDestroyCannotAffectNewSession() {
        val state = AssistantWakeLifecycle()
        val old = state.sessionOpened()
        state.sessionClosed(old)
        val current = state.sessionOpened()
        assertFalse(state.isCurrentSession(old))
        assertFalse(state.sessionClosed(old))
        assertTrue(state.isCurrentSession(current))
        assertFalse(state.canListen)
    }

    @Test fun hostDestroyedBeforePanelStillWaitsForPanelToClose() {
        val state = AssistantWakeLifecycle()
        val session = state.sessionOpened()
        val host = Any()
        state.hostOpened(host)
        state.hostClosed(host)
        assertFalse(state.canListen)
        state.sessionClosed(session)
        assertTrue(state.canListen)
    }

    @Test fun staleHostCleanupCannotRemoveNewHost() {
        val state = AssistantWakeLifecycle()
        val oldHost = Any()
        val newHost = Any()
        state.hostOpened(oldHost)
        state.hostOpened(newHost)
        state.hostClosed(oldHost)
        state.hostClosed(oldHost)
        assertFalse(state.canListen)
        state.hostClosed(newHost)
        assertTrue(state.canListen)
    }
}
