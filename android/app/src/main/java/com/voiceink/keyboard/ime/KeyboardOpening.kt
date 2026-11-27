package com.voiceink.keyboard.ime

import com.voiceink.keyboard.dictation.DictationState

/** What the keyboard does when its input view is shown on a field. */
internal object KeyboardOpening {
    data class Decision(val state: DictationState, val startRecording: Boolean)

    /**
     * Shows the resting state for [current] and starts recording right away when a fresh
     * recording makes sense: the view opened anew ([restarting] is false) on a [textField],
     * and nothing is in progress, kept or blocked by setup ([blocker]: no Mac and no on-device
     * model, or no microphone).
     */
    fun decide(
        current: DictationState,
        restarting: Boolean,
        textField: Boolean,
        blocker: DictationState?,
        hasKeptRecording: Boolean,
    ): Decision {
        if (current == DictationState.Recording || current.isBusy) return Decision(current, false)
        val resting = DictationState.resting(current, blocker, hasKeptRecording, sameField = restarting)
        val freshRecording = resting == DictationState.Idle || resting == DictationState.NoSpeech ||
            resting == DictationState.InsertedOnPhone
        return Decision(resting, startRecording = freshRecording && !restarting && textField)
    }
}
