package com.voiceink.keyboard.bubble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BubbleVisibilityTest {
    private val textField = FocusedField(editable = true, password = false)

    private fun shows(keyboardShown: Boolean = true, ownKeyboard: Boolean = false, field: FocusedField? = textField) =
        BubbleVisibility.shouldShow(keyboardShown, ownKeyboard, field)

    @Test fun appearsWhileAKeyboardIsOpenOnATextField() {
        assertTrue(shows())
    }

    @Test fun disappearsWhenTheKeyboardCloses() {
        assertFalse(shows(keyboardShown = false))
    }

    @Test fun neverAppearsInPasswordFields() {
        assertFalse(shows(field = FocusedField(editable = true, password = true)))
    }

    @Test fun staysHiddenWithoutAnEditableFocusedField() {
        assertFalse(shows(field = null))
        assertFalse(shows(field = FocusedField(editable = false, password = false)))
    }

    @Test fun staysHiddenWhileTheVoiceInkKeyboardIsTheOpenKeyboard() {
        assertFalse(shows(ownKeyboard = true))
    }
}
