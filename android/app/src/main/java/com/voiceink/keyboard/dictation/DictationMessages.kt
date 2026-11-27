package com.voiceink.keyboard.dictation

import android.content.Context
import com.voiceink.keyboard.R
import com.voiceink.keyboard.api.ApiError

/** The status line and extra action every dictation entry point shows for a [DictationState]. */
internal object DictationMessages {
    /** [phoneOffered]: the kept recording can be transcribed on the phone ([TranscriptionRoute.offersPhone]). */
    fun status(
        context: Context,
        state: DictationState,
        macName: String,
        copyAvailable: Boolean = false,
        phoneOffered: Boolean = false,
    ): String = when (state) {
        DictationState.Idle -> context.getString(R.string.status_idle)
        DictationState.Recording -> context.getString(R.string.status_recording)
        DictationState.Sending -> context.getString(R.string.status_sending, macName)
        DictationState.TranscribingOnPhone -> context.getString(R.string.status_transcribing_on_phone)
        DictationState.InsertedOnPhone -> context.getString(R.string.status_inserted_on_phone)
        DictationState.NoSpeech -> context.getString(R.string.status_no_speech)
        DictationState.RecorderFailed -> context.getString(R.string.status_recorder_failed)
        DictationState.NotPaired -> context.getString(R.string.status_not_paired)
        DictationState.NeedsOfflineModel -> context.getString(R.string.status_needs_offline_model)
        DictationState.NeedsMicrophone -> context.getString(R.string.status_needs_mic)
        is DictationState.Kept -> when (val e = state.error) {
            null -> when (state.reason) {
                KeptReason.INTERRUPTED -> context.getString(R.string.status_kept)
                KeptReason.FIELD_CHANGED -> context.getString(R.string.status_field_changed)
                KeptReason.REJECTED -> context.getString(
                    if (copyAvailable) R.string.status_insert_rejected_copy else R.string.status_insert_rejected,
                )
                KeptReason.PHONE_FAILED -> context.getString(R.string.status_phone_failed)
                KeptReason.PHONE_MODEL_MISSING -> context.getString(R.string.status_phone_model_missing)
            }
            ApiError.Unreachable -> context.getString(
                if (phoneOffered) R.string.error_unreachable_phone_offered else R.string.error_unreachable,
            )
            ApiError.Unauthorized -> context.getString(R.string.error_unauthorized)
            is ApiError.NoModelSelected -> context.getString(R.string.error_no_model)
            is ApiError.TranscriptionFailed -> context.getString(R.string.error_transcription_failed)
            is ApiError.Server -> context.getString(R.string.error_server, e.code ?: e.httpStatus.toString())
            is ApiError.InvalidResponse -> context.getString(R.string.error_invalid_response)
        }
    }

    /**
     * The label of the action that fixes what blocks dictation, or offers the phone for a recording
     * the Mac could not take ([phoneOffered]); null when none is needed.
     */
    fun action(state: DictationState, phoneOffered: Boolean = false): Int? = when {
        state == DictationState.NotPaired || state == DictationState.NeedsOfflineModel -> R.string.action_open_app
        state == DictationState.NeedsMicrophone -> R.string.action_allow_mic
        state is DictationState.Kept && state.error == ApiError.Unauthorized -> R.string.action_pair_again
        state is DictationState.Kept && state.reason == KeptReason.PHONE_MODEL_MISSING -> R.string.action_open_app
        phoneOffered -> R.string.action_transcribe_on_phone
        else -> null
    }
}
