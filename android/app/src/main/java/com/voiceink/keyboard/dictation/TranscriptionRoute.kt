package com.voiceink.keyboard.dictation

import com.voiceink.keyboard.api.ApiError
import com.voiceink.keyboard.offline.PhoneFailure

/** Where a recording is transcribed. */
internal enum class Engine {
    /** The paired Mac: its modes, dictionary, replacements, AI cleanup and History. */
    MAC,

    /** The on-device model: raw text only. */
    PHONE,
}

/**
 * Pure routing rules: the paired Mac whenever one is set up, unless the user turned on Offline
 * mode; the phone when there is no Mac and the model is downloaded; and the phone after the Mac
 * turns out unreachable, automatically or when the user asks.
 */
internal object TranscriptionRoute {
    /** The engine for a new or retried recording, or null when neither can take it. */
    fun engine(paired: Boolean, offlineMode: Boolean, phoneReady: Boolean): Engine? = when {
        offlineMode -> if (phoneReady) Engine.PHONE else null
        paired -> Engine.MAC
        phoneReady -> Engine.PHONE
        else -> null
    }

    /** What setup still needs before dictating, or null when nothing blocks it. */
    fun blocker(paired: Boolean, offlineMode: Boolean, phoneReady: Boolean, hasMicrophone: Boolean): DictationState? = when {
        engine(paired, offlineMode, phoneReady) == null ->
            if (offlineMode) DictationState.NeedsOfflineModel else DictationState.NotPaired
        !hasMicrophone -> DictationState.NeedsMicrophone
        else -> null
    }

    /** After the Mac failed with [error]: transcribe the kept recording on the phone right away. */
    fun fallBackAutomatically(error: ApiError, autoFallback: Boolean, phoneReady: Boolean): Boolean =
        error == ApiError.Unreachable && autoFallback && phoneReady

    /** Whether [state] offers Transcribe on phone for its kept recording. */
    fun offersPhone(state: DictationState, phoneReady: Boolean): Boolean =
        phoneReady && state is DictationState.Kept && state.error == ApiError.Unreachable

    /** The state after the phone could not transcribe; the recording stays for Retry. */
    fun stateAfterPhoneFailure(failure: PhoneFailure): DictationState = DictationState.Kept(
        error = null,
        reason = if (failure == PhoneFailure.MODEL_MISSING) KeptReason.PHONE_MODEL_MISSING else KeptReason.PHONE_FAILED,
    )

    /** The state after the phone's [text] was offered to the field: like the Mac's, but marked as local when typed. */
    fun stateAfterPhoneDelivery(outcome: TextDelivery.Outcome, text: String): DictationState =
        if (outcome == TextDelivery.Outcome.INSERTED) DictationState.InsertedOnPhone else CopyFallback.stateAfterDelivery(outcome, text)
}
