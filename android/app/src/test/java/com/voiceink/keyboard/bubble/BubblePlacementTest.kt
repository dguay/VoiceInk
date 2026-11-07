package com.voiceink.keyboard.bubble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BubblePlacementTest {
    private val margin = 20
    private val size = 150

    /** A 1080-wide portrait screen with a 60 px status bar and the keyboard's top at [keyboardTop]. */
    private fun portrait(keyboardTop: Int = 1500) = Box(0, 60, 1080, keyboardTop)

    private fun place(field: Box?, rtl: Boolean = false, area: Box = portrait(), position: BubblePosition? = null, height: Int = size) =
        BubblePlacement.place(area, position, field, width = size, height = height, margin = margin, rtl = rtl)

    private fun Box.isInside(area: Box) =
        left >= area.left + margin && right <= area.right - margin && top >= area.top + margin && bottom <= area.bottom - margin

    @Test fun docksJustAboveTheKeyboardAtTheEndSide() {
        assertEquals(Box(910, 1330, 1060, 1480), place(field = Box(40, 200, 1040, 320)))
    }

    @Test fun docksAtTheLeftInRightToLeftLayouts() {
        assertEquals(Box(20, 1330, 170, 1480), place(field = null, rtl = true))
    }

    @Test fun movesToTheStartSideRatherThanCoverTheField() {
        val field = Box(600, 1350, 1060, 1450)

        val box = place(field)

        assertEquals(Box(20, 1330, 170, 1480), box)
        assertFalse(box.intersects(field))
    }

    @Test fun goesAboveAFullWidthFieldSittingOnTheKeyboard() {
        val chatInput = Box(0, 1380, 1080, 1500)

        val box = place(chatInput)

        assertEquals(Box(910, 1210, 1060, 1360), box)
        assertFalse(box.intersects(chatInput))
    }

    @Test fun aDroppedBubbleComesBackWhereItWasDropped() {
        val dropped = BubblePlacement.clamp(portrait(), 300, 900, size, size, margin)

        val position = BubblePlacement.positionOf(portrait(), dropped, margin)

        assertEquals(dropped, place(field = null, position = position))
    }

    @Test fun aSavedPlaceIsKeptEvenOverTheField() {
        val position = BubblePosition(across = 0f, lift = 200)

        assertEquals(Box(20, 1150, 170, 1300), place(field = Box(0, 1100, 1080, 1200), position = position))
    }

    @Test fun followsTheKeyboardWhenItGrows() {
        val position = BubblePosition(across = 0.5f, lift = 100)

        val withLetters = place(field = null, position = position, area = portrait(keyboardTop = 1500))
        val withEmojiPanel = place(field = null, position = position, area = portrait(keyboardTop = 1200))

        assertEquals(1400, withLetters.bottom)
        assertEquals(1100, withEmojiPanel.bottom)
        assertEquals(withLetters.left, withEmojiPanel.left)
    }

    @Test fun keepsItsShareOfTheWidthAcrossRotation() {
        val rightEdge = BubblePosition(across = 1f, lift = 100)
        val landscape = Box(0, 60, 2340, 600)

        assertEquals(2340 - margin, place(field = null, position = rightEdge, area = landscape).right)
        assertEquals(1080 - margin, place(field = null, position = rightEdge).right)
    }

    @Test fun neverEndsUpUnderTheKeyboardOrOffScreen() {
        val area = portrait()
        val corners = listOf(-500 to -500, 5000 to -500, -500 to 5000, 5000 to 5000, 460 to 1450)

        for ((left, top) in corners) {
            assertTrue("dragged to ($left, $top)", BubblePlacement.clamp(area, left, top, size, size, margin).isInside(area))
        }
    }

    @Test fun aLiftTallerThanTheSpaceLeftKeepsTheBubbleBelowTheStatusBar() {
        val shortLandscape = Box(0, 60, 2340, 500)

        val box = place(field = null, position = BubblePosition(across = 0.5f, lift = 1200), area = shortLandscape)

        assertTrue(box.isInside(shortLandscape))
    }

    @Test fun staysOnScreenWhenTheBubbleIsTallerThanTheSpaceAboveTheKeyboard() {
        val box = place(field = null, area = portrait(keyboardTop = 300), height = 400)

        assertEquals(80, box.top)
    }
}
