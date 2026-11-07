package com.voiceink.keyboard.bubble

/** The input-focused field, as the bubble sees it. */
internal data class FocusedField(val editable: Boolean, val password: Boolean)

/** Whether the mic bubble is on screen. */
internal object BubbleVisibility {
    /**
     * Shown only while a keyboard is open over an editable, non-password field, and not while the
     * VoiceInk voice keyboard itself ([ownKeyboard]) is that keyboard: it already dictates.
     */
    fun shouldShow(keyboardShown: Boolean, ownKeyboard: Boolean, field: FocusedField?): Boolean =
        keyboardShown && !ownKeyboard && field != null && field.editable && !field.password
}

/**
 * Follows the field the bubble serves and turns each change into a new delivery session: text
 * requested in one field is never typed into another ([TextDelivery][com.voiceink.keyboard.dictation.TextDelivery]).
 * A null field means the bubble is hidden.
 */
internal class FieldSessions<K : Any>(private val start: () -> Unit, private val end: () -> Unit) {
    var current: K? = null
        private set

    /** Returns true when the field changed. */
    fun update(field: K?): Boolean {
        if (field == current) return false
        if (current != null) end()
        if (field != null) start()
        current = field
        return true
    }
}

/** A screen rectangle in pixels. */
internal data class Box(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    fun intersects(other: Box): Boolean =
        left < other.right && other.left < right && top < other.bottom && other.top < bottom
}

/** Where the bubble goes on screen. */
internal object BubblePlacement {
    /**
     * The bubble's box for a [width] × [height] bubble: docked just above [keyboardTop] at the end
     * side of a [screenWidth]-wide screen, or at the start side when that would cover [field], or
     * above [field] when both sides would.
     */
    fun place(screenWidth: Int, keyboardTop: Int, field: Box?, width: Int, height: Int, margin: Int, rtl: Boolean = false): Box {
        val top = keyboardTop - margin - height
        val endSide = boxAt(if (rtl) margin else screenWidth - margin - width, top, width, height)
        val startSide = boxAt(if (rtl) screenWidth - margin - width else margin, top, width, height)
        if (field == null) return endSide
        listOf(endSide, startSide).firstOrNull { !it.intersects(field) }?.let { return it }
        val aboveField = boxAt(endSide.left, (field.top - margin - height).coerceAtLeast(margin), width, height)
        return if (aboveField.intersects(field)) endSide else aboveField
    }

    private fun boxAt(left: Int, top: Int, width: Int, height: Int) = Box(left, top, left + width, top + height)
}
