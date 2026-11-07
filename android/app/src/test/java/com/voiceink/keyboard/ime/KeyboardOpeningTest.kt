package com.voiceink.keyboard.ime

import com.voiceink.keyboard.api.ApiError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardOpeningTest {
    private fun open(
        current: KeyboardState = KeyboardState.Idle,
        restarting: Boolean = false,
        textField: Boolean = true,
        paired: Boolean = true,
        hasMicrophone: Boolean = true,
        hasKeptRecording: Boolean = false,
    ) = KeyboardOpening.decide(current, restarting, textField, paired, hasMicrophone, hasKeptRecording)

    @Test fun openingOnATextFieldStartsRecording() {
        assertTrue(open().startRecording)
    }

    @Test fun openingAfterNoSpeechOrARecorderFailureStartsAFreshRecording() {
        assertTrue(open(current = KeyboardState.NoSpeech).startRecording)
        assertTrue(open(current = KeyboardState.RecorderFailed).startRecording)
    }

    @Test fun keptRecordingWaitsForRetryOrDiscardWithItsError() {
        val kept = KeyboardState.Kept(ApiError.Unreachable)

        val decision = open(current = kept, hasKeptRecording = true)

        assertEquals(kept, decision.state)
        assertFalse(decision.startRecording)
    }

    @Test fun keptRecordingFromAnEarlierSessionShowsRetry() {
        val decision = open(hasKeptRecording = true)

        assertEquals(KeyboardState.Kept(null), decision.state)
        assertFalse(decision.startRecording)
    }

    @Test fun unpairedPhoneAsksToPairInsteadOfRecording() {
        val decision = open(paired = false, hasMicrophone = false, hasKeptRecording = true)

        assertEquals(KeyboardState.NotPaired, decision.state)
        assertFalse(decision.startRecording)
    }

    @Test fun missingMicrophonePermissionAsksForItInsteadOfRecording() {
        val decision = open(hasMicrophone = false)

        assertEquals(KeyboardState.NeedsMicrophone, decision.state)
        assertFalse(decision.startRecording)
    }

    @Test fun recordingOrSendingInProgressIsLeftAloneWithoutASecondRecording() {
        for (busy in listOf(KeyboardState.Recording, KeyboardState.Sending)) {
            for (restarting in listOf(true, false)) {
                val decision = open(current = busy, restarting = restarting)

                assertEquals(busy, decision.state)
                assertFalse(decision.startRecording)
            }
        }
    }

    @Test fun restartingOnTheSameFieldKeepsTheRestingStateWithoutRecording() {
        assertEquals(KeyboardOpening.Decision(KeyboardState.Idle, false), open(restarting = true))
        assertEquals(
            KeyboardOpening.Decision(KeyboardState.NoSpeech, false),
            open(current = KeyboardState.NoSpeech, restarting = true),
        )
    }

    @Test fun viewWithoutATextFieldDoesNotRecord() {
        assertEquals(KeyboardOpening.Decision(KeyboardState.Idle, false), open(textField = false))
    }
}
