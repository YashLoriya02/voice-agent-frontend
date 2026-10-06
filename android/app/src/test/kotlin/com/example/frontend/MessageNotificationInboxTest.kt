package com.example.frontend

import org.junit.Assert.*
import org.junit.Test

class MessageNotificationInboxTest {
    private val now = 100_000_000L
    private fun message(id: String, key: String = "chat", time: Long = now) = CapturedMessage(
        id, key, "whatsapp", "WhatsApp", "Yash", "", "Hello", time,
    )

    @Test fun updatesDoNotRepeatSpokenMessages() {
        val inbox = MessageNotificationInbox()
        inbox.capture(listOf(message("one")), now)
        inbox.acknowledge(listOf("one"), now)
        inbox.capture(listOf(message("one"), message("two", time = now + 1)), now + 1)
        assertEquals(listOf("two"), inbox.messages(now + 1, true).map { it.id })
        assertEquals(2, inbox.messages(now + 1).size)
    }

    @Test fun retrievalDoesNotAcknowledge() {
        val inbox = MessageNotificationInbox(listOf(message("one")))
        repeat(2) { assertEquals(1, inbox.messages(now, true).size) }
        assertTrue(inbox.spokenIds(now).isEmpty())
    }

    @Test fun dismissalAndReconnectRemoveNewPreviewsButKeepReplayHistory() {
        val inbox = MessageNotificationInbox(listOf(message("one", "a"), message("two", "b")))
        inbox.removeNotification("a")
        assertEquals(listOf("two"), inbox.messages(now, true).map { it.id })
        assertEquals(2, inbox.messages(now).size)
        inbox.reconcile(emptySet())
        assertTrue(inbox.messages(now, true).isEmpty())
        assertEquals(2, inbox.messages(now).size)
    }

    @Test fun spokenDismissedMessageCanBeReplayedAfterReload() {
        val inbox = MessageNotificationInbox(listOf(message("one")))
        inbox.acknowledge(listOf("one"), now)
        inbox.removeNotification("chat")
        val restored = MessageNotificationInbox(inbox.messages(now), inbox.spokenIds(now), inbox.activeNotificationKeys(now))
        assertTrue(restored.messages(now, true).isEmpty())
        assertEquals("one", restored.messages(now).single().id)
        restored.reconcile(emptySet())
        assertEquals("Hello", restored.messages(now).single().body)
    }

    @Test fun acknowledgementSurvivesCacheReloadAndReposting() {
        val inbox = MessageNotificationInbox(listOf(message("one")))
        inbox.acknowledge(listOf("one"), now)
        val restored = MessageNotificationInbox(inbox.messages(now), inbox.spokenIds(now))
        restored.removeNotification("chat")
        restored.capture(listOf(message("one")), now)
        assertTrue(restored.messages(now, true).isEmpty())
    }

    @Test fun expiredPreviewsAndReceiptsArePruned() {
        val inbox = MessageNotificationInbox(listOf(message("one")))
        inbox.acknowledge(listOf("one"), now)
        assertTrue(inbox.messages(now + MessageNotificationInbox.RETENTION_MS + 1).isEmpty())
        assertTrue(inbox.spokenIds(now + MessageNotificationInbox.RETENTION_MS + 1).isEmpty())
    }

    @Test fun cacheIsBoundedAndOnlyRequestedIdsAreAcknowledged() {
        val inbox = MessageNotificationInbox()
        inbox.capture((0..300).map { message("$it", time = now + it) }, now + 300)
        assertEquals(MessageNotificationInbox.MAX_MESSAGES, inbox.messages(now + 300).size)
        inbox.acknowledge(listOf("300", "missing"), now + 300)
        assertEquals(setOf("300"), inbox.spokenIds(now + 300).keys)
        assertEquals(249, inbox.messages(now + 300, true).size)
    }
}
