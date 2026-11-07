package com.voiceink.keyboard.bubble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class BubblePlacementTest {
    private val screenWidth = 1080
    private val keyboardTop = 1500
    private val margin = 20

    private fun place(field: Box?, rtl: Boolean = false) =
        BubblePlacement.place(screenWidth, keyboardTop, field, width = 150, height = 150, margin = margin, rtl = rtl)

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
}
