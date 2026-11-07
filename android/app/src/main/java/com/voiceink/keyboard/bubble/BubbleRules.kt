package com.voiceink.keyboard.bubble

/** The input-focused field, as the bubble sees it, and the package of the [app] it belongs to. */
internal data class FocusedField(val editable: Boolean, val password: Boolean, val app: String? = null)

/** Whether the mic bubble is on screen. */
internal object BubbleVisibility {
    /**
     * Shown only while a keyboard is open over an editable, non-password field, and not while the
     * VoiceInk voice keyboard itself ([ownKeyboard]) is that keyboard: it already dictates. Never
     * shown in a field of one of the [excludedApps] the user picked.
     */
    fun shouldShow(
        keyboardShown: Boolean,
        ownKeyboard: Boolean,
        field: FocusedField?,
        excludedApps: Set<String> = emptySet(),
    ): Boolean =
        keyboardShown && !ownKeyboard && field != null && field.editable && !field.password &&
            field.app !in excludedApps
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

/**
 * Where the user dragged the bubble, kept relative to the keyboard so it follows the keyboard as it
 * opens, closes, resizes or rotates: [across] is the share of the free width left of the bubble (0 =
 * left edge, 1 = right edge) and [lift] the gap in pixels between the bubble's bottom and the
 * keyboard's top.
 */
internal data class BubblePosition(val across: Float, val lift: Int)

/** Where the bubble goes on screen. */
internal object BubblePlacement {
    /**
     * The bubble's box for a [width] × [height] bubble inside [area] (the usable screen; its bottom is
     * the keyboard's top): at the user's [position] when there is one, otherwise docked just above
     * the keyboard at the end side, or at the start side when that would cover [field], or above
     * [field] when both sides would. Always [clamped][clamp].
     */
    fun place(area: Box, position: BubblePosition?, field: Box?, width: Int, height: Int, margin: Int, rtl: Boolean = false): Box {
        if (position != null) {
            val free = freeWidth(area, width, margin)
            val left = area.left + margin + (position.across.coerceIn(0f, 1f) * free).toInt()
            return clamp(area, left, area.bottom - position.lift - height, width, height, margin)
        }
        return clamp(area, dock(area, field, width, height, margin, rtl), margin)
    }

    /**
     * Moves a [width] × [height] box whose top-left corner is at ([left], [top]) inside [area], at
     * least [margin] from its edges: fully on screen and above the keyboard. When the space above the
     * keyboard is shorter than the bubble, it stays on screen and overlaps the keyboard.
     */
    fun clamp(area: Box, left: Int, top: Int, width: Int, height: Int, margin: Int): Box {
        val x = left.coerceAtMost(area.right - margin - width).coerceAtLeast(area.left + margin)
        val y = top.coerceAtMost(area.bottom - margin - height).coerceAtLeast(area.top + margin)
        return Box(x, y, x + width, y + height)
    }

    /** The position that puts a bubble at [box] (already [clamped][clamp] in [area]), to remember where it was dropped. */
    fun positionOf(area: Box, box: Box, margin: Int): BubblePosition {
        val free = freeWidth(area, box.right - box.left, margin)
        val across = if (free == 0) 1f else ((box.left - area.left - margin).toFloat() / free).coerceIn(0f, 1f)
        return BubblePosition(across, (area.bottom - box.bottom).coerceAtLeast(margin))
    }

    private fun clamp(area: Box, box: Box, margin: Int) =
        clamp(area, box.left, box.top, box.right - box.left, box.bottom - box.top, margin)

    private fun freeWidth(area: Box, width: Int, margin: Int) = (area.right - area.left - 2 * margin - width).coerceAtLeast(0)

    private fun dock(area: Box, field: Box?, width: Int, height: Int, margin: Int, rtl: Boolean): Box {
        val top = area.bottom - margin - height
        val endSide = boxAt(if (rtl) area.left + margin else area.right - margin - width, top, width, height)
        val startSide = boxAt(if (rtl) area.right - margin - width else area.left + margin, top, width, height)
        if (field == null) return endSide
        listOf(endSide, startSide).firstOrNull { !it.intersects(field) }?.let { return it }
        val aboveField = boxAt(endSide.left, (field.top - margin - height).coerceAtLeast(area.top + margin), width, height)
        return if (aboveField.intersects(field)) endSide else aboveField
    }

    private fun boxAt(left: Int, top: Int, width: Int, height: Int) = Box(left, top, left + width, top + height)
}
