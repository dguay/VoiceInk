package com.voiceink.keyboard.corrections

import android.text.InputType
import com.voiceink.keyboard.api.ApiError
import com.voiceink.keyboard.api.CorrectionSnapshot

/** A dictation just typed into a field: its History [historyId], the [text] typed and, when known, where it [start]s. */
data class InsertedDictation(val historyId: String, val text: String, val start: Int?)

/**
 * Hands a dictation typed by the voice keyboard or the bubble to the bubble's accessibility service,
 * the only part of the app that can see the field afterwards (the voice keyboard gives the field
 * back to the previous keyboard right away). In process only: nothing is stored, and with the
 * bubble's service off nobody listens and the dictation is not observed.
 */
object CorrectionHandoff {
    fun interface Listener {
        fun onInserted(dictation: InsertedDictation)
    }

    @Volatile private var listener: Listener? = null

    fun register(listener: Listener) {
        this.listener = listener
    }

    fun unregister(listener: Listener) {
        if (this.listener === listener) this.listener = null
    }

    fun inserted(dictation: InsertedDictation) {
        listener?.onInserted(dictation)
    }
}

/** Fields whose text is never observed. */
object PasswordFields {
    fun isPassword(flaggedPassword: Boolean, inputType: Int): Boolean {
        if (flaggedPassword) return true
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        return when (inputType and InputType.TYPE_MASK_CLASS) {
            InputType.TYPE_CLASS_TEXT -> variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
            InputType.TYPE_CLASS_NUMBER -> variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }
    }
}

/** Finds the dictation in the field text read right after it was typed. */
object InsertLocator {
    /** [hint] when [text] is there, otherwise its only occurrence; null when it is not found or ambiguous. */
    fun locate(field: String, text: String, hint: Int?): Int? {
        if (text.isEmpty()) return null
        if (hint != null && hint >= 0 && field.regionMatches(hint, text, 0, text.length)) return hint
        val first = field.indexOf(text)
        if (first < 0 || field.indexOf(text, first + 1) >= 0) return null
        return first
    }
}

/**
 * Cuts what leaves the phone: the same window of the field, [RADIUS] UTF-16 code units before and
 * after the dictation, right after it was typed and when the user left the field. Nothing outside
 * the window is sent. Returns null (nothing is sent) when the field did not change, when the text
 * outside the window changed (the window could not be told apart), or when it grew by more than
 * [MAX_GROWTH].
 */
object CorrectionWindow {
    const val RADIUS = 200
    const val MAX_GROWTH = 2_000
    /** The Mac's Auto-Learn ignores longer dictations. */
    const val MAX_INSERTED = 12_000

    fun cut(historyId: String, inserted: String, afterInsert: String, whenLeft: String, start: Int): CorrectionSnapshot? {
        if (inserted.isEmpty() || inserted.length > MAX_INSERTED) return null
        if (start < 0 || !afterInsert.regionMatches(start, inserted, 0, inserted.length)) return null
        if (afterInsert == whenLeft) return null

        val end = start + inserted.length
        var windowStart = (start - RADIUS).coerceAtLeast(0)
        // Never split a surrogate pair; shrinking keeps the window within the radius.
        if (windowStart > 0 && Character.isLowSurrogate(afterInsert[windowStart])) windowStart++
        var windowEnd = (end + RADIUS).coerceAtMost(afterInsert.length)
        if (windowEnd < afterInsert.length && Character.isLowSurrogate(afterInsert[windowEnd])) windowEnd--

        val before = afterInsert.substring(0, windowStart)
        val after = afterInsert.substring(windowEnd)
        if (whenLeft.length < before.length + after.length || !whenLeft.startsWith(before) || !whenLeft.endsWith(after)) {
            return null
        }
        val leftWindow = whenLeft.substring(windowStart, whenLeft.length - after.length)
        if (leftWindow.length > (windowEnd - windowStart) + MAX_GROWTH) return null
        return CorrectionSnapshot(
            historyId = historyId,
            insertedText = inserted,
            textAfterInsert = afterInsert.substring(windowStart, windowEnd),
            textWhenLeft = leftWindow,
            insertStart = start - windowStart,
        )
    }
}

/** Where input focus is, relative to the field being observed. */
enum class Focus { ON_FIELD, OTHER_FIELD, NONE }

/**
 * Watches one field after a dictation was typed into it, one look at a time, and decides when the
 * user is done: focus moved to another field, focus left with no field taking it, the keyboard
 * closed, or [timeoutMs] passed. A password field is never observed. Focus and keyboard must be
 * gone for [graceMs] (the voice keyboard handing back to the previous keyboard briefly closes it).
 */
class FieldObservation(
    private val startedAt: Long,
    private val timeoutMs: Long = TIMEOUT_MS,
    private val graceMs: Long = GRACE_MS,
) {
    enum class Decision(val sends: Boolean) {
        WATCH(false),
        FIELD_CHANGED(true),
        FOCUS_LEFT(true),
        KEYBOARD_CLOSED(true),
        TIMED_OUT(true),
        PASSWORD_FIELD(false),
    }

    private var focusGoneSince: Long? = null
    private var keyboardGoneSince: Long? = null

    /** The field's text at the last look while it had focus; an emptied field (a sent message) keeps the earlier text. */
    var lastText: String? = null
        private set

    fun look(now: Long, focus: Focus, password: Boolean, keyboardOpen: Boolean, fieldText: String?): Decision {
        if (password) return Decision.PASSWORD_FIELD
        if (focus == Focus.ON_FIELD && !fieldText.isNullOrEmpty()) lastText = fieldText
        if (focus == Focus.OTHER_FIELD) return Decision.FIELD_CHANGED
        if (now - startedAt >= timeoutMs) return Decision.TIMED_OUT

        focusGoneSince = if (focus == Focus.NONE) focusGoneSince ?: now else null
        keyboardGoneSince = if (!keyboardOpen) keyboardGoneSince ?: now else null
        focusGoneSince?.let { if (now - it >= graceMs) return Decision.FOCUS_LEFT }
        keyboardGoneSince?.let { if (now - it >= graceMs) return Decision.KEYBOARD_CLOSED }
        return Decision.WATCH
    }

    companion object {
        const val TIMEOUT_MS = 60_000L
        const val GRACE_MS = 600L
        /** How often the field is looked at while observed. */
        const val LOOK_INTERVAL_MS = 250L
    }
}

/** A snapshot is sent at most [MAX_ATTEMPTS] times, and retried only when no Mac could be reached. */
object CorrectionSending {
    const val MAX_ATTEMPTS = 3
    const val RETRY_DELAY_MS = 3_000L

    /** Whether to try again after [attempt] (1-based) failed with [error]. */
    fun shouldRetry(attempt: Int, error: ApiError): Boolean =
        attempt < MAX_ATTEMPTS && error == ApiError.Unreachable
}
