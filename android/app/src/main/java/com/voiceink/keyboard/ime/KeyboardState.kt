package com.voiceink.keyboard.ime

import com.voiceink.keyboard.api.ApiError

/** What the voice keyboard is doing, and what it shows. */
internal sealed interface KeyboardState {
    data object Idle : KeyboardState
    data object Recording : KeyboardState
    data object Sending : KeyboardState
    data object NoSpeech : KeyboardState

    /** A kept recording waits for a retry; [error] is null when no request failed. */
    data class Kept(val error: ApiError?, val reason: KeptReason = KeptReason.INTERRUPTED) : KeyboardState
    data object NotPaired : KeyboardState
    data object NeedsMicrophone : KeyboardState
    data object RecorderFailed : KeyboardState
}

enum class KeptReason { INTERRUPTED, FIELD_CHANGED, REJECTED }

/** What the keyboard does when its input view is shown on a field. */
internal object KeyboardOpening {
    data class Decision(val state: KeyboardState, val startRecording: Boolean)

    /**
     * Shows the resting state for [current] and starts recording right away when a fresh
     * recording makes sense: the view opened anew ([restarting] is false) on a [textField],
     * and nothing is in progress, kept, unpaired or missing the microphone.
     */
    fun decide(
        current: KeyboardState,
        restarting: Boolean,
        textField: Boolean,
        paired: Boolean,
        hasMicrophone: Boolean,
        hasKeptRecording: Boolean,
    ): Decision {
        if (current == KeyboardState.Recording || current == KeyboardState.Sending) return Decision(current, false)
        val resting = when {
            !paired -> KeyboardState.NotPaired
            !hasMicrophone -> KeyboardState.NeedsMicrophone
            hasKeptRecording -> current as? KeyboardState.Kept ?: KeyboardState.Kept(null)
            current == KeyboardState.NoSpeech -> KeyboardState.NoSpeech
            else -> KeyboardState.Idle
        }
        val freshRecording = resting == KeyboardState.Idle || resting == KeyboardState.NoSpeech
        return Decision(resting, startRecording = freshRecording && !restarting && textField)
    }
}
