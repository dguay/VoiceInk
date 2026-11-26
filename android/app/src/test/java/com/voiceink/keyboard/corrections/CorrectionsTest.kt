package com.voiceink.keyboard.corrections

import android.text.InputType
import com.voiceink.keyboard.api.ApiError
import com.voiceink.keyboard.api.CorrectionSnapshot
import com.voiceink.keyboard.corrections.FieldObservation.Decision
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FieldObservationTest {
    private fun observation() = FieldObservation(startedAt = 0, timeoutMs = 10_000, graceMs = 500)

    @Test fun keepsWatchingWhileTheFieldHasFocusAndTheKeyboardIsOpen() {
        val o = observation()
        assertEquals(Decision.WATCH, o.look(100, Focus.ON_FIELD, password = false, keyboardOpen = true, fieldText = "a"))
        assertEquals(Decision.WATCH, o.look(9_000, Focus.ON_FIELD, password = false, keyboardOpen = true, fieldText = "ab"))
        assertEquals("ab", o.lastText)
    }

    @Test fun focusLeavingEndsTheObservationAfterTheGrace() {
        val o = observation()
        o.look(100, Focus.ON_FIELD, false, true, "Parakeet")
        assertEquals(Decision.WATCH, o.look(200, Focus.NONE, false, true, null))
        assertEquals(Decision.WATCH, o.look(600, Focus.NONE, false, true, null))
        val end = o.look(700, Focus.NONE, false, true, null)
        assertEquals(Decision.FOCUS_LEFT, end)
        assertTrue(end.sends)
        assertEquals("Parakeet", o.lastText)
    }

    @Test fun focusComingBackWithinTheGraceKeepsWatching() {
        val o = observation()
        o.look(200, Focus.NONE, false, true, null)
        o.look(400, Focus.ON_FIELD, false, true, "x")
        assertEquals(Decision.WATCH, o.look(800, Focus.NONE, false, true, null))
    }

    @Test fun anotherFieldTakingFocusEndsTheObservationAtOnce() {
        val o = observation()
        o.look(100, Focus.ON_FIELD, false, true, "Parakeet")
        val end = o.look(200, Focus.OTHER_FIELD, false, true, "other field text")
        assertEquals(Decision.FIELD_CHANGED, end)
        assertTrue(end.sends)
        assertEquals("Parakeet", o.lastText) // Another field's text is never taken.
    }

    @Test fun theKeyboardClosingEndsTheObservationAfterTheGrace() {
        val o = observation()
        // The voice keyboard handing back to the previous keyboard closes it only briefly.
        assertEquals(Decision.WATCH, o.look(100, Focus.ON_FIELD, false, false, "a"))
        assertEquals(Decision.WATCH, o.look(300, Focus.ON_FIELD, false, true, "a"))
        assertEquals(Decision.WATCH, o.look(400, Focus.ON_FIELD, false, false, "a"))
        val end = o.look(900, Focus.ON_FIELD, false, false, "a")
        assertEquals(Decision.KEYBOARD_CLOSED, end)
        assertTrue(end.sends)
    }

    @Test fun theTimeLimitEndsTheObservation() {
        val o = observation()
        assertEquals(Decision.WATCH, o.look(9_999, Focus.ON_FIELD, false, true, "a"))
        val end = o.look(10_000, Focus.ON_FIELD, false, true, "b")
        assertEquals(Decision.TIMED_OUT, end)
        assertTrue(end.sends)
        assertEquals("b", o.lastText)
    }

    @Test fun aPasswordFieldIsNeverObservedOrSent() {
        val o = observation()
        val end = o.look(100, Focus.ON_FIELD, password = true, keyboardOpen = true, fieldText = "hunter2")
        assertEquals(Decision.PASSWORD_FIELD, end)
        assertFalse(end.sends)
        assertNull(o.lastText)
    }

    @Test fun anEmptiedFieldKeepsTheLastText() {
        val o = observation()
        o.look(100, Focus.ON_FIELD, false, true, "Parakeet")
        o.look(200, Focus.ON_FIELD, false, true, "")
        assertEquals("Parakeet", o.lastText)
    }
}

class PasswordFieldsTest {
    @Test fun passwordFlagsAndInputTypesAreRecognised() {
        assertTrue(PasswordFields.isPassword(true, InputType.TYPE_CLASS_TEXT))
        for (variation in listOf(
            InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
        )) {
            assertTrue(PasswordFields.isPassword(false, InputType.TYPE_CLASS_TEXT or variation))
        }
        assertTrue(PasswordFields.isPassword(false, InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD))
        assertFalse(PasswordFields.isPassword(false, InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE))
        assertFalse(PasswordFields.isPassword(false, InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS))
        assertFalse(PasswordFields.isPassword(false, InputType.TYPE_NULL))
    }
}

class InsertLocatorTest {
    @Test fun usesTheHintWhenTheTextIsThereOtherwiseItsOnlyOccurrence() {
        assertEquals(5, InsertLocator.locate("Note Parakeat", "Parakeat", 5))
        assertEquals(5, InsertLocator.locate("Note Parakeat", "Parakeat", 2))
        assertEquals(5, InsertLocator.locate("Note Parakeat", "Parakeat", null))
        assertNull(InsertLocator.locate("hi hi", "hi", null))
        assertEquals(3, InsertLocator.locate("hi hi", "hi", 3))
        assertNull(InsertLocator.locate("nothing here", "Parakeat", 0))
    }
}

class CorrectionWindowTest {
    private val before = "B".repeat(1_000)
    private val after = "A".repeat(1_000)

    @Test fun onlyTheWindowAroundTheDictationLeavesThePhone() {
        val inserted = "Dictate with Parakeat today"
        val afterInsert = before + inserted + after
        val whenLeft = before + "Dictate with Parakeet today" + after

        val snapshot = CorrectionWindow.cut("id-1", inserted, afterInsert, whenLeft, before.length)!!

        val radius = CorrectionWindow.RADIUS
        assertEquals("B".repeat(radius) + inserted + "A".repeat(radius), snapshot.textAfterInsert)
        assertEquals("B".repeat(radius) + "Dictate with Parakeet today" + "A".repeat(radius), snapshot.textWhenLeft)
        assertEquals(radius, snapshot.insertStart)
        assertEquals(inserted, snapshot.insertedText)

        // What is sent on the wire holds nothing beyond the window.
        val json = JSONObject(snapshot.toJson())
        assertEquals(setOf("id", "insertedText", "textAfterInsert", "textWhenLeft", "insertStart"), json.keys().asSequence().toSet())
        assertEquals("id-1", json.getString("id"))
        assertTrue(json.getString("textAfterInsert").length <= inserted.length + 2 * radius)
        assertTrue(json.getString("textWhenLeft").length <= "Dictate with Parakeet today".length + 2 * radius)
        assertFalse(snapshot.toJson().contains("B".repeat(radius + 1)))
        assertFalse(snapshot.toJson().contains("A".repeat(radius + 1)))
    }

    @Test fun aShortFieldIsSentWhole() {
        val snapshot = CorrectionWindow.cut("id", "Parakeat", "Note: Parakeat", "Note: Parakeet", 6)
        assertEquals(CorrectionSnapshot("id", "Parakeat", "Note: Parakeat", "Note: Parakeet", 6), snapshot)
    }

    @Test fun nothingIsSentWhenTheFieldDidNotChange() {
        assertNull(CorrectionWindow.cut("id", "Parakeet", "Parakeet", "Parakeet", 0))
    }

    @Test fun nothingIsSentWhenTextOutsideTheWindowChanged() {
        val inserted = "Parakeat"
        val afterInsert = before + inserted + after
        assertNull(CorrectionWindow.cut("id", inserted, afterInsert, "X" + before.drop(1) + "Parakeet" + after, before.length))
        assertNull(CorrectionWindow.cut("id", inserted, afterInsert, before + "Parakeet" + after.dropLast(1) + "X", before.length))
        assertNull(CorrectionWindow.cut("id", inserted, afterInsert, "", before.length))
    }

    @Test fun nothingIsSentWhenTheFieldGrewTooMuchOrThePositionIsWrong() {
        val grown = "Note: " + "x".repeat(CorrectionWindow.MAX_GROWTH + 100)
        assertNull(CorrectionWindow.cut("id", "Parakeat", "Note: Parakeat", grown, 6))
        assertNull(CorrectionWindow.cut("id", "Parakeat", "Note: Parakeat", "Note: Parakeet", 5))
        assertNull(CorrectionWindow.cut("id", "", "Note: ", "Note: x", 6))
    }

    @Test fun theWindowNeverSplitsASurrogatePair() {
        val emoji = "😀" // One emoji, two UTF-16 code units.
        val inserted = "Parakeat"
        // The window start would fall between the two halves of the emoji.
        val prefix = "a" + emoji + "b".repeat(CorrectionWindow.RADIUS - 1)
        val afterInsert = prefix + inserted
        val snapshot = CorrectionWindow.cut("id", inserted, afterInsert, prefix + "Parakeet", prefix.length)!!
        assertFalse(Character.isLowSurrogate(snapshot.textAfterInsert.first()))
        assertFalse(Character.isLowSurrogate(snapshot.textWhenLeft.first()))
        assertEquals(inserted, snapshot.textAfterInsert.substring(snapshot.insertStart, snapshot.insertStart + inserted.length))
    }
}

class CorrectionSendingTest {
    @Test fun aSnapshotIsTriedAFewTimesAndOnlyWhenTheMacWasUnreachable() {
        assertTrue(CorrectionSending.shouldRetry(1, ApiError.Unreachable))
        assertTrue(CorrectionSending.shouldRetry(2, ApiError.Unreachable))
        assertFalse(CorrectionSending.shouldRetry(CorrectionSending.MAX_ATTEMPTS, ApiError.Unreachable))
        assertFalse(CorrectionSending.shouldRetry(1, ApiError.Unauthorized))
        assertFalse(CorrectionSending.shouldRetry(1, ApiError.Server(404, "unknown_dictation", null)))
    }
}

class CorrectionHandoffTest {
    @Test fun aDictationReachesOnlyARegisteredListener() {
        val received = mutableListOf<InsertedDictation>()
        val listener = CorrectionHandoff.Listener { received += it }
        val dictation = InsertedDictation("id", "Parakeat", 0)

        CorrectionHandoff.inserted(dictation)
        CorrectionHandoff.register(listener)
        CorrectionHandoff.inserted(dictation)
        CorrectionHandoff.unregister(listener)
        CorrectionHandoff.inserted(dictation)

        assertEquals(listOf(dictation), received)
    }
}
