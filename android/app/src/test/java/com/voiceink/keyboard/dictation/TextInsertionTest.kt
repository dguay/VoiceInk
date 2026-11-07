package com.voiceink.keyboard.dictation

import org.junit.Assert.assertEquals
import org.junit.Test

class TextInsertionTest {
    @Test fun insertsAtTheCursorWithASpaceAfterAWord() {
        assertEquals(TextInsertion.Edit("Buy milk today", 8), TextInsertion.insert("Buy today", 3, 3, "milk"))
    }

    @Test fun replacesTheSelection() {
        assertEquals(TextInsertion.Edit("Buy bread", 9), TextInsertion.insert("Buy milk", 8, 4, "bread"))
    }

    @Test fun startsAnEmptyFieldWithoutASpace() {
        assertEquals(TextInsertion.Edit("Hello.", 6), TextInsertion.insert("", 0, 0, "Hello."))
    }

    @Test fun appendsWhenTheCursorIsUnknown() {
        assertEquals(TextInsertion.Edit("Hi there", 8), TextInsertion.insert("Hi", -1, -1, "there"))
    }
}
