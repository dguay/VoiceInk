package com.voiceink.keyboard.dictation

/**
 * Pure rules for the copy-only fallback when an editor rejects accessibility text insertion: keeps
 * the transcribed text available for a one-tap copy, and clears the kept recording and error state
 * only once the text is actually on the clipboard.
 */
internal object CopyFallback {
    /** Maps a [TextDelivery.deliver] [outcome] and trimmed [text] to the resulting [DictationState]. */
    fun stateAfterDelivery(outcome: TextDelivery.Outcome, text: String): DictationState = when (outcome) {
        TextDelivery.Outcome.INSERTED -> DictationState.Idle
        TextDelivery.Outcome.EMPTY -> DictationState.NoSpeech
        TextDelivery.Outcome.FIELD_CHANGED -> DictationState.Kept(null, KeptReason.FIELD_CHANGED)
        TextDelivery.Outcome.REJECTED -> DictationState.Kept(null, KeptReason.REJECTED, text = text)
    }

    /** Whether a one-tap Copy fallback action is available for [state]. */
    fun isAvailable(state: DictationState): Boolean =
        state is DictationState.Kept && state.reason == KeptReason.REJECTED && !state.text.isNullOrBlank()

    /**
     * Copies the rejected transcription from [state] via [copyToClipboard]. When copying succeeds,
     * drops the kept recording via [discard] and returns [DictationState.Idle]; otherwise leaves
     * [state] and the recording untouched so the transcription is never lost.
     */
    fun copy(
        state: DictationState,
        copyToClipboard: (String) -> Boolean,
        discard: () -> Unit,
    ): DictationState {
        if (!isAvailable(state)) return state
        val text = (state as DictationState.Kept).text ?: return state
        if (!copyToClipboard(text)) return state
        discard()
        return DictationState.Idle
    }
}
