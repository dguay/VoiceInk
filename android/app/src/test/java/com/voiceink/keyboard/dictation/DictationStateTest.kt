package com.voiceink.keyboard.dictation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DictationStateTest {
    private fun resting(current: DictationState, sameField: Boolean) =
        DictationState.resting(current, blocker = null, hasKeptRecording = false, sameField = sameField)

    @Test fun theNothingHeardHintDoesNotFollowToTheNextField() {
        assertEquals(DictationState.Idle, resting(DictationState.NoSpeech, sameField = false))
    }

    @Test fun theNothingHeardHintStaysWhenTheSameFieldRestarts() {
        assertEquals(DictationState.NoSpeech, resting(DictationState.NoSpeech, sameField = true))
    }

    @Test fun theOnPhoneMarkerStaysOnItsFieldOnly() {
        assertEquals(DictationState.InsertedOnPhone, resting(DictationState.InsertedOnPhone, sameField = true))
        assertEquals(DictationState.Idle, resting(DictationState.InsertedOnPhone, sameField = false))
    }

    @Test fun setupBlockersComeBeforeAKeptRecording() {
        val resting = DictationState.resting(
            DictationState.Kept(null),
            blocker = DictationState.NeedsOfflineModel,
            hasKeptRecording = true,
            sameField = false,
        )
        assertEquals(DictationState.NeedsOfflineModel, resting)
    }

    @Test fun onlyTranscriptionsInProgressAreBusy() {
        assertTrue(DictationState.Sending.isBusy)
        assertTrue(DictationState.TranscribingOnPhone.isBusy)
        assertFalse(DictationState.Recording.isBusy)
        assertFalse(DictationState.InsertedOnPhone.isBusy)
    }
}
