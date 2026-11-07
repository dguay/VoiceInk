package com.voiceink.keyboard.dictation

import com.voiceink.keyboard.api.ApiError

/** What a dictation entry point (the voice keyboard or the mic bubble) is doing, and what it shows. */
sealed interface DictationState {
    data object Idle : DictationState
    data object Recording : DictationState
    data object Sending : DictationState
    data object NoSpeech : DictationState

    /** A kept recording waits for a retry; [error] is null when no request failed. */
    data class Kept(val error: ApiError?, val reason: KeptReason = KeptReason.INTERRUPTED) : DictationState
    data object NotPaired : DictationState
    data object NeedsMicrophone : DictationState
    data object RecorderFailed : DictationState

    companion object {
        /**
         * The state to show when an entry point appears on a field while nothing is in progress:
         * what setup still needs, then a kept recording waiting for Retry, then [current]'s
         * "nothing heard" hint when it reappears on the [sameField] (a restart), else idle. The hint
         * belongs to the attempt that heard nothing, so it never follows to another field.
         */
        fun resting(
            current: DictationState,
            paired: Boolean,
            hasMicrophone: Boolean,
            hasKeptRecording: Boolean,
            sameField: Boolean,
        ): DictationState = when {
            !paired -> NotPaired
            !hasMicrophone -> NeedsMicrophone
            hasKeptRecording -> current as? Kept ?: Kept(null)
            current == NoSpeech && sameField -> NoSpeech
            else -> Idle
        }
    }
}

enum class KeptReason { INTERRUPTED, FIELD_CHANGED, REJECTED }
