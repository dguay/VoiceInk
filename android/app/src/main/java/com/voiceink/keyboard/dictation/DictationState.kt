package com.voiceink.keyboard.dictation

import com.voiceink.keyboard.api.ApiError

/** What a dictation entry point (the voice keyboard or the mic bubble) is doing, and what it shows. */
sealed interface DictationState {
    data object Idle : DictationState
    data object Recording : DictationState
    data object Sending : DictationState

    /** The on-device model is transcribing the kept recording. */
    data object TranscribingOnPhone : DictationState
    data object NoSpeech : DictationState

    /** The last dictation was transcribed on the phone and typed: raw text, without the Mac's cleanup. */
    data object InsertedOnPhone : DictationState

    /**
     * A kept recording waits for a retry; [error] is null when no request failed. When the editor
     * rejected text insertion ([KeptReason.REJECTED]), [text] holds the transcription so the user
     * can copy it to the clipboard in one tap.
     */
    data class Kept(
        val error: ApiError?,
        val reason: KeptReason = KeptReason.INTERRUPTED,
        val text: String? = null,
    ) : DictationState
    data object NotPaired : DictationState

    /** Offline mode is on but the on-device model is not downloaded. */
    data object NeedsOfflineModel : DictationState
    data object NeedsMicrophone : DictationState
    data object RecorderFailed : DictationState

    /** A transcription is in progress, on the Mac or on the phone. */
    val isBusy: Boolean get() = this == Sending || this == TranscribingOnPhone

    companion object {
        /**
         * The state to show when an entry point appears on a field while nothing is in progress:
         * what setup still needs ([blocker], see [TranscriptionRoute.blocker]), then a kept
         * recording waiting for Retry, then [current]'s "nothing heard" or "typed on the phone"
         * hint when it reappears on the [sameField] (a restart), else idle. A hint belongs to the
         * attempt it describes, so it never follows to another field.
         */
        fun resting(
            current: DictationState,
            blocker: DictationState?,
            hasKeptRecording: Boolean,
            sameField: Boolean,
        ): DictationState = when {
            blocker != null -> blocker
            hasKeptRecording -> current as? Kept ?: Kept(null)
            (current == NoSpeech || current == InsertedOnPhone) && sameField -> current
            else -> Idle
        }
    }
}

enum class KeptReason {
    INTERRUPTED,
    FIELD_CHANGED,
    REJECTED,

    /** The on-device model could not transcribe it. */
    PHONE_FAILED,

    /** The on-device model was needed but is not downloaded. */
    PHONE_MODEL_MISSING,
}
