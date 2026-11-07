package com.voiceink.keyboard.ime

import com.voiceink.keyboard.dictation.DictationState

/** What the keyboard does when its input view is shown on a field. */
internal object KeyboardOpening {
    data class Decision(val state: DictationState, val startRecording: Boolean)

    /**
     * Shows the resting state for [current] and starts recording right away when a fresh
     * recording makes sense: the view opened anew ([restarting] is false) on a [textField],
     * and nothing is in progress, kept, unpaired or missing the microphone.
     */
    fun decide(
        current: DictationState,
        restarting: Boolean,
        textField: Boolean,
        paired: Boolean,
        hasMicrophone: Boolean,
        hasKeptRecording: Boolean,
    ): Decision {
        if (current == DictationState.Recording || current == DictationState.Sending) return Decision(current, false)
        val resting = DictationState.resting(current, paired, hasMicrophone, hasKeptRecording, sameField = restarting)
        val freshRecording = resting == DictationState.Idle || resting == DictationState.NoSpeech
        return Decision(resting, startRecording = freshRecording && !restarting && textField)
    }
}
