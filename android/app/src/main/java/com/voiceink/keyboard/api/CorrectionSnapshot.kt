package com.voiceink.keyboard.api

import org.json.JSONObject

/**
 * The body of `POST /v1/corrections` (docs/phone-dictation-api.md). Both texts are the same
 * bounded window of the field around the dictation, never the whole field; see
 * [CorrectionWindow][com.voiceink.keyboard.corrections.CorrectionWindow].
 */
data class CorrectionSnapshot(
    /** The History `id` returned by `POST /v1/transcribe`. */
    val historyId: String,
    /** The dictated text as it was typed into the field. */
    val insertedText: String,
    /** The window of the field right after the dictation was typed. */
    val textAfterInsert: String,
    /** The same window when the user left the field. */
    val textWhenLeft: String,
    /** Where [insertedText] starts in [textAfterInsert], in UTF-16 code units. */
    val insertStart: Int,
) {
    fun toJson(): String = JSONObject()
        .put("id", historyId)
        .put("insertedText", insertedText)
        .put("textAfterInsert", textAfterInsert)
        .put("textWhenLeft", textWhenLeft)
        .put("insertStart", insertStart)
        .toString()
}
