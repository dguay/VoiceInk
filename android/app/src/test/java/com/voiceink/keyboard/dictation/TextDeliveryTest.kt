package com.voiceink.keyboard.dictation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TextDeliveryTest {
    private val delivery = TextDelivery().apply { startSession() }
    private val committed = mutableListOf<String>()
    private var recordingKept = true

    private fun deliver(ticket: TextDelivery.Ticket, text: String, accepts: Boolean = true) =
        delivery.deliver(ticket, text, { committed += it; accepts }, { recordingKept = false })

    @Test fun insertsIntoTheFieldTheRequestStartedInAndDeletesTheRecording() {
        val ticket = delivery.ticket()

        assertEquals(TextDelivery.Outcome.INSERTED, deliver(ticket, "Pick up milk."))
        assertEquals(listOf("Pick up milk."), committed)
        assertFalse(recordingKept)
    }

    @Test fun delayedResponseAfterMovingToAnotherFieldIsNotTypedThere() {
        val ticket = delivery.ticket()
        delivery.endSession() // left field A
        delivery.startSession() // focused field B before the Mac answered

        assertEquals(TextDelivery.Outcome.FIELD_CHANGED, deliver(ticket, "for field A"))
        assertTrue(committed.isEmpty())
        assertTrue(recordingKept)
    }

    @Test fun responseAfterTheKeyboardClosedIsKept() {
        val ticket = delivery.ticket()
        delivery.endSession()

        assertEquals(TextDelivery.Outcome.FIELD_CHANGED, deliver(ticket, "text"))
        assertTrue(recordingKept)
    }

    @Test fun anEditorRestartInTheSameFieldStillReceivesTheText() {
        val ticket = delivery.ticket()
        delivery.startSession(sameField = true)

        assertEquals(TextDelivery.Outcome.INSERTED, deliver(ticket, "text"))
    }

    @Test fun rejectedCommitKeepsTheRecordingForRetry() {
        assertEquals(TextDelivery.Outcome.REJECTED, deliver(delivery.ticket(), "text", accepts = false))
        assertTrue(recordingKept)

        // The retry, once the editor accepts input, inserts and only then deletes it.
        assertEquals(TextDelivery.Outcome.INSERTED, deliver(delivery.ticket(), "text"))
        assertFalse(recordingKept)
    }

    @Test fun emptyTranscriptionTypesNothingAndDropsTheRecording() {
        assertEquals(TextDelivery.Outcome.EMPTY, deliver(delivery.ticket(), "  "))
        assertTrue(committed.isEmpty())
        assertFalse(recordingKept)
    }
}
