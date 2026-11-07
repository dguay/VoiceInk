package com.voiceink.keyboard.ime

import com.voiceink.keyboard.api.ApiError
import com.voiceink.keyboard.dictation.DictationState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardOpeningTest {
    private fun open(
        current: DictationState = DictationState.Idle,
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
        assertTrue(open(current = DictationState.NoSpeech).startRecording)
        assertTrue(open(current = DictationState.RecorderFailed).startRecording)
    }

    @Test fun keptRecordingWaitsForRetryOrDiscardWithItsError() {
        val kept = DictationState.Kept(ApiError.Unreachable)

        val decision = open(current = kept, hasKeptRecording = true)

        assertEquals(kept, decision.state)
        assertFalse(decision.startRecording)
    }

    @Test fun keptRecordingFromAnEarlierSessionShowsRetry() {
        val decision = open(hasKeptRecording = true)

        assertEquals(DictationState.Kept(null), decision.state)
        assertFalse(decision.startRecording)
    }

    @Test fun unpairedPhoneAsksToPairInsteadOfRecording() {
        val decision = open(paired = false, hasMicrophone = false, hasKeptRecording = true)

        assertEquals(DictationState.NotPaired, decision.state)
        assertFalse(decision.startRecording)
    }

    @Test fun missingMicrophonePermissionAsksForItInsteadOfRecording() {
        val decision = open(hasMicrophone = false)

        assertEquals(DictationState.NeedsMicrophone, decision.state)
        assertFalse(decision.startRecording)
    }

    @Test fun recordingOrSendingInProgressIsLeftAloneWithoutASecondRecording() {
        for (busy in listOf(DictationState.Recording, DictationState.Sending)) {
            for (restarting in listOf(true, false)) {
                val decision = open(current = busy, restarting = restarting)

                assertEquals(busy, decision.state)
                assertFalse(decision.startRecording)
            }
        }
    }

    @Test fun restartingOnTheSameFieldKeepsTheRestingStateWithoutRecording() {
        assertEquals(KeyboardOpening.Decision(DictationState.Idle, false), open(restarting = true))
        assertEquals(
            KeyboardOpening.Decision(DictationState.NoSpeech, false),
            open(current = DictationState.NoSpeech, restarting = true),
        )
    }

    @Test fun viewWithoutATextFieldDoesNotRecord() {
        assertEquals(KeyboardOpening.Decision(DictationState.Idle, false), open(textField = false))
    }
}
