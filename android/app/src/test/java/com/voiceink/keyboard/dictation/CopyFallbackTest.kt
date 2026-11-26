package com.voiceink.keyboard.dictation

import com.voiceink.keyboard.api.ApiError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CopyFallbackTest {
    @Test fun rejectedDeliveryKeepsTranscriptionAndEnablesCopy() {
        val state = CopyFallback.stateAfterDelivery(TextDelivery.Outcome.REJECTED, "Pick up milk.")

        assertEquals(DictationState.Kept(null, KeptReason.REJECTED, text = "Pick up milk."), state)
        assertTrue(CopyFallback.isAvailable(state))
    }

    @Test fun copyPutsTranscriptionOnClipboardDiscardsRecordingAndClearsErrorState() {
        val rejected = CopyFallback.stateAfterDelivery(TextDelivery.Outcome.REJECTED, "Pick up milk.")
        val copied = mutableListOf<String>()
        var discarded = false

        val next = CopyFallback.copy(
            state = rejected,
            copyToClipboard = { copied += it; true },
            discard = { discarded = true },
        )

        assertEquals(listOf("Pick up milk."), copied)
        assertTrue(discarded)
        assertEquals(DictationState.Idle, next)
    }

    @Test fun failedClipboardWriteLeavesRecordingAndErrorStateIntact() {
        val rejected = CopyFallback.stateAfterDelivery(TextDelivery.Outcome.REJECTED, "Pick up milk.")
        var discarded = false

        val next = CopyFallback.copy(
            state = rejected,
            copyToClipboard = { false },
            discard = { discarded = true },
        )

        assertFalse(discarded)
        assertEquals(rejected, next)
    }

    @Test fun nonRejectedAndBlankKeptStatesDoNotOfferCopy() {
        val unavailable = listOf(
            CopyFallback.stateAfterDelivery(TextDelivery.Outcome.INSERTED, "text"),
            CopyFallback.stateAfterDelivery(TextDelivery.Outcome.EMPTY, ""),
            CopyFallback.stateAfterDelivery(TextDelivery.Outcome.FIELD_CHANGED, "text"),
            DictationState.Kept(null, KeptReason.INTERRUPTED),
            DictationState.Kept(ApiError.Unreachable),
            DictationState.Kept(ApiError.Unauthorized),
            DictationState.Kept(null, KeptReason.REJECTED, text = null),
            DictationState.Kept(null, KeptReason.REJECTED, text = "   "),
            DictationState.Idle,
            DictationState.Recording,
            DictationState.Sending,
            DictationState.NoSpeech,
        )

        for (state in unavailable) {
            assertFalse("Copy should not be available for $state", CopyFallback.isAvailable(state))
            var copied = false
            var discarded = false
            assertEquals(state, CopyFallback.copy(state, { copied = true; true }, { discarded = true }))
            assertFalse(copied)
            assertFalse(discarded)
        }
    }

    @Test fun restingStatePreservesRejectedTranscriptionUntilCopied() {
        val rejected = CopyFallback.stateAfterDelivery(TextDelivery.Outcome.REJECTED, "Meet at noon")

        val preserved = DictationState.resting(
            current = rejected,
            paired = true,
            hasMicrophone = true,
            hasKeptRecording = true,
            sameField = false,
        )
        assertEquals(rejected, preserved)
        assertTrue(CopyFallback.isAvailable(preserved))

        var recordingKept = true
        val afterCopy = CopyFallback.copy(preserved, { true }, { recordingKept = false })
        val afterResting = DictationState.resting(
            current = afterCopy,
            paired = true,
            hasMicrophone = true,
            hasKeptRecording = recordingKept,
            sameField = false,
        )
        assertEquals(DictationState.Idle, afterResting)
    }
}
