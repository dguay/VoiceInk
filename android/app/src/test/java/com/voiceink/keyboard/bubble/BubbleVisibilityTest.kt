package com.voiceink.keyboard.bubble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BubbleVisibilityTest {
    private val textField = FocusedField(editable = true, password = false, app = "com.example.chat")

    private fun shows(
        keyboardShown: Boolean = true,
        ownKeyboard: Boolean = false,
        field: FocusedField? = textField,
        excludedApps: Set<String> = emptySet(),
    ) = BubbleVisibility.shouldShow(keyboardShown, ownKeyboard, field, excludedApps)

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

    @Test fun neverAppearsInAnExcludedApp() {
        assertFalse(shows(excludedApps = setOf("com.example.chat")))
    }

    @Test fun removingAnAppFromTheExclusionsBringsTheBubbleBack() {
        val excluded = setOf("com.example.chat", "com.example.game")

        assertTrue(shows(excludedApps = excluded - "com.example.chat"))
    }

    @Test fun aKeyboardSlidingAwayIsAlreadyGone() {
        // SwiftKey 185 ms after Back on a 2340 px tall screen.
        assertFalse(BubbleVisibility.keyboardAtRest(Box(0, 1769, 1080, 2717), screenBottom = 2340))
    }

    @Test fun aKeyboardAtRestReachesTheScreenBottomExactly() {
        assertTrue(BubbleVisibility.keyboardAtRest(Box(0, 1392, 1080, 2340), screenBottom = 2340))
    }
}
