package com.voiceink.keyboard.bubble

import com.voiceink.keyboard.api.ApiError
import com.voiceink.keyboard.dictation.DictationState
import com.voiceink.keyboard.dictation.KeptReason
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BubbleIdleCollapseTest {
    private val collapse = BubbleIdleCollapse()

    @Test fun offByDefaultNeverSchedulesOrCollapses() {
        collapse.onShow(IdleCollapseTimeout.OFF, DictationState.Idle, now = 0)

        assertFalse(collapse.collapsed)
        assertNull(collapse.remainingDelayMs(now = 0))
        assertFalse(collapse.onTimeout(now = 60_000))
        assertFalse(collapse.collapsed)
    }

    @Test fun collapsesAfterConfiguredTimeoutWhenUntouched() {
        for (timeout in listOf(IdleCollapseTimeout.SECONDS_5, IdleCollapseTimeout.SECONDS_10, IdleCollapseTimeout.SECONDS_30)) {
            val state = BubbleIdleCollapse()
            state.onShow(timeout, DictationState.Idle, now = 1_000)

            assertEquals(timeout.delayMs, state.remainingDelayMs(now = 1_000))
            assertFalse(state.onTimeout(now = 1_000 + timeout.delayMs - 1))
            assertFalse(state.collapsed)

            assertTrue(state.onTimeout(now = 1_000 + timeout.delayMs))
            assertTrue(state.collapsed)
            assertNull(state.remainingDelayMs(now = 1_000 + timeout.delayMs))
        }
    }

    @Test fun repeatedShowUpdatesWhileTypingDoNotResetTimerOrUncollapse() {
        collapse.onShow(IdleCollapseTimeout.SECONDS_5, DictationState.Idle, now = 0)

        // Typing triggers accessibility updates that call show() again without touching the bubble.
        collapse.onShow(IdleCollapseTimeout.SECONDS_5, DictationState.Idle, now = 3_000)
        assertEquals(2_000L, collapse.remainingDelayMs(now = 3_000))

        assertTrue(collapse.onTimeout(now = 5_000))
        assertTrue(collapse.collapsed)

        collapse.onShow(IdleCollapseTimeout.SECONDS_5, DictationState.Idle, now = 7_000)
        assertTrue(collapse.collapsed)
        assertNull(collapse.remainingDelayMs(now = 7_000))
    }

    @Test fun tappingCollapsedHandleExpandsAndRestartsIdleTimer() {
        collapse.onShow(IdleCollapseTimeout.SECONDS_5, DictationState.Idle, now = 0)
        assertTrue(collapse.onTimeout(now = 5_000))
        assertTrue(collapse.collapsed)

        collapse.onExpand(now = 8_000)
        assertFalse(collapse.collapsed)
        assertEquals(5_000L, collapse.remainingDelayMs(now = 8_000))
        assertFalse(collapse.onTimeout(now = 12_999))
        assertTrue(collapse.onTimeout(now = 13_000))
        assertTrue(collapse.collapsed)
    }

    @Test fun touchingAndDraggingSuppressesCollapseAndRestartsTimerOnRelease() {
        collapse.onShow(IdleCollapseTimeout.SECONDS_5, DictationState.Idle, now = 0)

        collapse.onTouchStarted()
        assertNull(collapse.remainingDelayMs(now = 4_000))
        assertFalse(collapse.onTimeout(now = 20_000))
        assertFalse(collapse.collapsed)

        collapse.onTouchEnded(now = 21_000)
        assertEquals(5_000L, collapse.remainingDelayMs(now = 21_000))
        assertFalse(collapse.onTimeout(now = 25_999))
        assertTrue(collapse.onTimeout(now = 26_000))
        assertTrue(collapse.collapsed)
    }

    @Test fun neverCollapsesWhileRecordingSendingKeptOrShowingErrorPill() {
        val suppressedStates = listOf(
            DictationState.Recording,
            DictationState.Sending,
            DictationState.TranscribingOnPhone,
            DictationState.InsertedOnPhone,
            DictationState.Kept(null, KeptReason.PHONE_FAILED),
            DictationState.Kept(null, KeptReason.INTERRUPTED),
            DictationState.Kept(null, KeptReason.FIELD_CHANGED),
            DictationState.Kept(null, KeptReason.REJECTED, text = "Hello world"),
            DictationState.Kept(ApiError.Unreachable),
            DictationState.NoSpeech,
            DictationState.RecorderFailed,
            DictationState.NotPaired,
            DictationState.NeedsOfflineModel,
            DictationState.NeedsMicrophone,
        )

        for (suppressed in suppressedStates) {
            val state = BubbleIdleCollapse()
            state.onShow(IdleCollapseTimeout.SECONDS_5, suppressed, now = 0)

            assertFalse("should stay expanded in $suppressed", state.collapsed)
            assertNull("should not schedule timer in $suppressed", state.remainingDelayMs(now = 0))
            assertFalse("should not collapse on timeout in $suppressed", state.onTimeout(now = 30_000))
        }
    }

    @Test fun enteringSuppressedStateWhileCollapsedExpandsAndReturningToIdleRestartsTimer() {
        collapse.onShow(IdleCollapseTimeout.SECONDS_5, DictationState.Idle, now = 0)
        assertTrue(collapse.onTimeout(now = 5_000))
        assertTrue(collapse.collapsed)

        collapse.sync(IdleCollapseTimeout.SECONDS_5, DictationState.Kept(ApiError.Unreachable), now = 6_000)
        assertFalse(collapse.collapsed)
        assertNull(collapse.remainingDelayMs(now = 6_000))

        collapse.sync(IdleCollapseTimeout.SECONDS_5, DictationState.Idle, now = 10_000)
        assertFalse(collapse.collapsed)
        assertEquals(5_000L, collapse.remainingDelayMs(now = 10_000))
        assertTrue(collapse.onTimeout(now = 15_000))
        assertTrue(collapse.collapsed)
    }

    @Test fun closingAndReopeningKeyboardRestoresExpandedStartingState() {
        collapse.onShow(IdleCollapseTimeout.SECONDS_5, DictationState.Idle, now = 0)
        assertTrue(collapse.onTimeout(now = 5_000))
        assertTrue(collapse.collapsed)

        collapse.onHide()
        assertFalse(collapse.collapsed)
        assertNull(collapse.remainingDelayMs(now = 6_000))

        collapse.onShow(IdleCollapseTimeout.SECONDS_5, DictationState.Idle, now = 10_000)
        assertFalse(collapse.collapsed)
        assertEquals(5_000L, collapse.remainingDelayMs(now = 10_000))
    }

    @Test fun disablingSettingWhileCollapsedExpandsImmediately() {
        collapse.onShow(IdleCollapseTimeout.SECONDS_5, DictationState.Idle, now = 0)
        assertTrue(collapse.onTimeout(now = 5_000))
        assertTrue(collapse.collapsed)

        collapse.sync(IdleCollapseTimeout.OFF, DictationState.Idle, now = 7_000)
        assertFalse(collapse.collapsed)
        assertNull(collapse.remainingDelayMs(now = 7_000))
    }

    @Test fun changingTimeoutWhileExpandedReschedulesFromNow() {
        collapse.onShow(IdleCollapseTimeout.SECONDS_30, DictationState.Idle, now = 0)
        assertEquals(30_000L, collapse.remainingDelayMs(now = 0))

        collapse.sync(IdleCollapseTimeout.SECONDS_5, DictationState.Idle, now = 4_000)
        assertEquals(5_000L, collapse.remainingDelayMs(now = 4_000))
        assertFalse(collapse.onTimeout(now = 8_999))
        assertTrue(collapse.onTimeout(now = 9_000))
    }

    @Test fun fromSecondsMapsKnownOptionsAndDefaultsUnknownToOff() {
        assertEquals(IdleCollapseTimeout.OFF, IdleCollapseTimeout.fromSeconds(0))
        assertEquals(IdleCollapseTimeout.SECONDS_5, IdleCollapseTimeout.fromSeconds(5))
        assertEquals(IdleCollapseTimeout.SECONDS_10, IdleCollapseTimeout.fromSeconds(10))
        assertEquals(IdleCollapseTimeout.SECONDS_30, IdleCollapseTimeout.fromSeconds(30))
        assertEquals(IdleCollapseTimeout.OFF, IdleCollapseTimeout.fromSeconds(-1))
        assertEquals(IdleCollapseTimeout.OFF, IdleCollapseTimeout.fromSeconds(99))
    }
}
