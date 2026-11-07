package com.voiceink.keyboard.bubble

import com.voiceink.keyboard.dictation.TextDelivery
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The bubble's text reaches only the field it was requested in. */
class FieldSessionsTest {
    private val delivery = TextDelivery()
    private val sessions = FieldSessions<String>(start = { delivery.startSession() }, end = { delivery.endSession() })
    private val typed = mutableListOf<String>()
    private var recordingKept = true

    private fun deliver(ticket: TextDelivery.Ticket) =
        delivery.deliver(ticket, "dictated", { typed += sessions.current!!; true }, { recordingKept = false })

    @Test fun textLandsInTheFieldTheBubbleWasOpenedFor() {
        sessions.update("message field")
        val ticket = delivery.ticket()
        sessions.update("message field") // later events on the same field

        assertEquals(TextDelivery.Outcome.INSERTED, deliver(ticket))
        assertEquals(listOf("message field"), typed)
    }

    @Test fun focusMovingToAnotherFieldKeepsTheRecordingInsteadOfTypingThere() {
        sessions.update("field A")
        val ticket = delivery.ticket()
        sessions.update("field B")

        assertEquals(TextDelivery.Outcome.FIELD_CHANGED, deliver(ticket))
        assertTrue(typed.isEmpty())
        assertTrue(recordingKept)
    }

    @Test fun keyboardClosingAndReopeningOnTheSameFieldStillKeepsTheRecordingForRetry() {
        sessions.update("field A")
        val ticket = delivery.ticket()
        sessions.update(null) // keyboard closed: the bubble hid
        sessions.update("field A")

        assertEquals(TextDelivery.Outcome.FIELD_CHANGED, deliver(ticket))
        assertTrue(recordingKept)

        // Retry from the field now open types there.
        assertEquals(TextDelivery.Outcome.INSERTED, deliver(delivery.ticket()))
    }

    @Test fun reportsOnlyActualFieldChanges() {
        assertTrue(sessions.update("field A"))
        assertEquals(false, sessions.update("field A"))
        assertTrue(sessions.update(null))
        assertEquals(false, sessions.update(null))
    }
}
