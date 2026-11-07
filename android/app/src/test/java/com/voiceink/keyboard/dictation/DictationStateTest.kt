package com.voiceink.keyboard.dictation

import org.junit.Assert.assertEquals
import org.junit.Test

class DictationStateTest {
    private fun resting(current: DictationState, sameField: Boolean) =
        DictationState.resting(current, paired = true, hasMicrophone = true, hasKeptRecording = false, sameField = sameField)

    @Test fun theNothingHeardHintDoesNotFollowToTheNextField() {
        assertEquals(DictationState.Idle, resting(DictationState.NoSpeech, sameField = false))
    }

    @Test fun theNothingHeardHintStaysWhenTheSameFieldRestarts() {
        assertEquals(DictationState.NoSpeech, resting(DictationState.NoSpeech, sameField = true))
    }
}
