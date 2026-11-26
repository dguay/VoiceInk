package com.voiceink.keyboard.bubble

import com.voiceink.keyboard.dictation.DictationState

/** How long the mic bubble sits untouched before tucking against the nearest screen edge. */
enum class IdleCollapseTimeout(val seconds: Int) {
    OFF(0),
    SECONDS_5(5),
    SECONDS_10(10),
    SECONDS_30(30);

    val delayMs: Long get() = seconds * 1000L
    val enabled: Boolean get() = seconds > 0

    companion object {
        fun fromSeconds(seconds: Int): IdleCollapseTimeout =
            entries.firstOrNull { it.seconds == seconds } ?: OFF
    }
}

/** Which physical side of the screen a collapsed handle tucks against. */
internal enum class ScreenEdge { LEFT, RIGHT }

/** Where the collapsed edge handle goes and which screen edge it is tucked against. */
internal data class CollapsedPlacement(val edge: ScreenEdge, val box: Box)

/** The input-focused field, as the bubble sees it, and the package of the [app] it belongs to. */
internal data class FocusedField(val editable: Boolean, val password: Boolean, val app: String? = null)

/** Whether the mic bubble is on screen. */
internal object BubbleVisibility {
    /**
     * Whether a keyboard window at [keyboard] is open and at rest. A keyboard sliding in or away
     * reaches below the screen's bottom edge ([screenBottom]): the bubble leaves with it at once
     * rather than float there until the keyboard is gone.
     */
    fun keyboardAtRest(keyboard: Box, screenBottom: Int): Boolean = keyboard.bottom <= screenBottom

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

    /** Which edge of [area] is closer to [box], breaking exact center ties toward the layout end side. */
    fun nearestEdge(area: Box, box: Box, rtl: Boolean = false): ScreenEdge {
        val distLeft = box.left - area.left
        val distRight = area.right - box.right
        return when {
            distLeft < distRight -> ScreenEdge.LEFT
            distRight < distLeft -> ScreenEdge.RIGHT
            rtl -> ScreenEdge.LEFT
            else -> ScreenEdge.RIGHT
        }
    }

    /**
     * Tucks a [handleWidth] × [handleHeight] edge handle flush against the nearest horizontal edge
     * of [area] for [expanded], vertically centered on [expanded] and clamped within [margin] of
     * [area]'s top and bottom edges.
     */
    fun dockCollapsed(
        area: Box,
        expanded: Box,
        handleWidth: Int,
        handleHeight: Int,
        margin: Int,
        rtl: Boolean = false,
    ): CollapsedPlacement {
        val edge = nearestEdge(area, expanded, rtl)
        val left = when (edge) {
            ScreenEdge.LEFT -> area.left
            ScreenEdge.RIGHT -> (area.right - handleWidth).coerceAtLeast(area.left)
        }
        val centerY = (expanded.top + expanded.bottom) / 2
        val top = (centerY - handleHeight / 2)
            .coerceAtMost(area.bottom - margin - handleHeight)
            .coerceAtLeast(area.top + margin)
        return CollapsedPlacement(edge, Box(left, top, left + handleWidth, top + handleHeight))
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

/**
 * Holds the bubble back while the keyboard and the field are still moving (a keyboard opening with
 * its app settles over a few hundred milliseconds, in steps), so it appears once, in place, instead
 * of jumping there. A look at time `now` (ms) is steady once the value has not changed for
 * [quietMs], or after waiting [maxWaitMs], so something that never stops moving cannot keep the
 * bubble away.
 */
internal class Steadiness<T : Any>(private val quietMs: Long = 250, private val maxWaitMs: Long = 1000) {
    private var last: T? = null
    private var changedAt = 0L
    private var waitingSince: Long? = null

    fun look(value: T, now: Long): Boolean {
        if (value != last) {
            last = value
            changedAt = now
        }
        val waitStart = waitingSince ?: now.also { waitingSince = it }
        val steady = now - changedAt >= quietMs || now - waitStart >= maxWaitMs
        if (steady) waitingSince = null
        return steady
    }

    /** The bubble hid: the next appearance waits for the screen to settle again. */
    fun reset() {
        last = null
        waitingSince = null
    }
}

/**
 * Tracks when an idle mic bubble should tuck against the nearest screen edge and when it must stay
 * expanded. Never collapses when [IdleCollapseTimeout.OFF], while hidden, while touched/dragged, or
 * in any non-[DictationState.Idle] state (recording, sending, kept recording, or error/setup card).
 * Repeated screen updates while typing do not reset the timer or uncollapse an edge handle; direct
 * touches reset the timer, and hiding (closing the keyboard) restores the expanded starting state.
 */
internal class BubbleIdleCollapse {
    var collapsed: Boolean = false
        private set

    private var visible = false
    private var touching = false
    private var timeout = IdleCollapseTimeout.OFF
    private var state: DictationState = DictationState.Idle
    private var deadlineMs: Long? = null

    /** Bubble appeared (or updated while already visible) at [now]. */
    fun onShow(timeout: IdleCollapseTimeout, state: DictationState, now: Long) {
        if (!visible) {
            visible = true
            collapsed = false
            touching = false
            this.timeout = timeout
            this.state = state
            deadlineMs = if (canCollapse()) now + timeout.delayMs else null
            return
        }
        sync(timeout, state, now)
    }

    /** Bubble hid (keyboard closed, password field, or excluded app): restore normal starting state. */
    fun onHide() {
        visible = false
        collapsed = false
        touching = false
        deadlineMs = null
    }

    /** Applies the latest [timeout] setting and dictation [state] at [now]. */
    fun sync(timeout: IdleCollapseTimeout, state: DictationState, now: Long) {
        if (!visible) {
            this.timeout = timeout
            this.state = state
            deadlineMs = null
            return
        }
        val prevTimeout = this.timeout
        val wasEligible = canCollapse()
        this.timeout = timeout
        this.state = state
        val nowEligible = canCollapse()

        if (!nowEligible) {
            collapsed = false
            deadlineMs = null
        } else if (collapsed) {
            deadlineMs = null
        } else if (!wasEligible || timeout != prevTimeout) {
            deadlineMs = now + timeout.delayMs
        }
    }

    /** Finger touched the bubble (tap or drag start): suppress collapse until released. */
    fun onTouchStarted() {
        touching = true
        deadlineMs = null
    }

    /** Finger left the bubble (tap or drag end): restart the idle timer from [now]. */
    fun onTouchEnded(now: Long) {
        touching = false
        if (canCollapse() && !collapsed) {
            deadlineMs = now + timeout.delayMs
        }
    }

    /** User tapped the collapsed edge handle: expand back to the mic button and restart the timer. */
    fun onExpand(now: Long) {
        collapsed = false
        deadlineMs = if (canCollapse()) now + timeout.delayMs else null
    }

    /** Fires when the scheduled timer elapses at [now]; returns true when the bubble collapsed. */
    fun onTimeout(now: Long): Boolean {
        val deadline = deadlineMs ?: return false
        if (!canCollapse() || collapsed || now < deadline) return false
        collapsed = true
        deadlineMs = null
        return true
    }

    /** Milliseconds until collapse should fire from [now], or null when no timer should be scheduled. */
    fun remainingDelayMs(now: Long): Long? {
        if (!canCollapse() || collapsed) return null
        val deadline = deadlineMs ?: return null
        return (deadline - now).coerceAtLeast(0L)
    }

    private fun canCollapse(): Boolean =
        visible && timeout.enabled && state == DictationState.Idle && !touching
}
