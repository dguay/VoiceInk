package com.voiceink.keyboard.bubble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SteadinessTest {
    private val steadiness = Steadiness<Int>(quietMs = 250, maxWaitMs = 1000)

    @Test fun waitsUntilTheKeyboardHasHeldStillBeforeShowing() {
        // Messenger reopening with its field focused: SwiftKey's top reads 1370, then settles at 1392.
        assertFalse(steadiness.look(1370, now = 0))
        assertFalse(steadiness.look(1370, now = 100)) // still, but not for long enough
        assertFalse(steadiness.look(1392, now = 170))
        assertFalse(steadiness.look(1392, now = 300))
        assertTrue(steadiness.look(1392, now = 420)) // shown once, at its final place
    }

    @Test fun staysSteadyWhileNothingMoves() {
        steadiness.look(1392, now = 0)
        assertTrue(steadiness.look(1392, now = 300))
        assertTrue(steadiness.look(1392, now = 5000))
    }

    @Test fun aKeyboardResizeWaitsForTheNewHeightToSettle() {
        steadiness.look(1392, now = 0)
        steadiness.look(1392, now = 300)

        assertFalse(steadiness.look(1100, now = 1000)) // emoji panel opening
        assertTrue(steadiness.look(1100, now = 1300))
    }

    @Test fun somethingThatNeverStopsMovingCannotKeepTheBubbleAway() {
        for (t in 0L until 1000L step 100) assertFalse(steadiness.look(t.toInt(), now = t))
        assertTrue(steadiness.look(-1, now = 1000))
    }

    @Test fun hidingStartsOver() {
        steadiness.look(1392, now = 0)
        steadiness.look(1392, now = 300)
        steadiness.reset()

        assertFalse(steadiness.look(1392, now = 400))
    }
}
