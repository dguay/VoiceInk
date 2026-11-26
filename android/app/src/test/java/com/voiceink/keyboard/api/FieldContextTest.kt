package com.voiceink.keyboard.api

import android.text.InputType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FieldContextTest {
    private fun kind(inputType: Int, isPassword: Boolean = false) = FieldKind.fromInputType(inputType, isPassword)

    @Test fun emailAddressVariationsAreEmail() {
        assertEquals(FieldKind.EMAIL, kind(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS))
        assertEquals(FieldKind.EMAIL, kind(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS))
        // Flags do not change the kind.
        assertEquals(
            FieldKind.EMAIL,
            kind(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS),
        )
    }

    @Test fun uriIsUrl() {
        assertEquals(FieldKind.URL, kind(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI))
    }

    @Test fun numbersAndPhoneNumbersAreNumber() {
        assertEquals(FieldKind.NUMBER, kind(InputType.TYPE_CLASS_NUMBER))
        assertEquals(FieldKind.NUMBER, kind(InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL or InputType.TYPE_NUMBER_FLAG_SIGNED))
        assertEquals(FieldKind.NUMBER, kind(InputType.TYPE_CLASS_PHONE))
    }

    @Test fun plainTextVariationsAreText() {
        for (variation in listOf(
            InputType.TYPE_TEXT_VARIATION_NORMAL,
            InputType.TYPE_TEXT_VARIATION_SHORT_MESSAGE,
            InputType.TYPE_TEXT_VARIATION_LONG_MESSAGE,
            InputType.TYPE_TEXT_VARIATION_EMAIL_SUBJECT,
            InputType.TYPE_TEXT_VARIATION_PERSON_NAME,
            InputType.TYPE_TEXT_VARIATION_POSTAL_ADDRESS,
            InputType.TYPE_TEXT_VARIATION_WEB_EDIT_TEXT,
            InputType.TYPE_TEXT_VARIATION_FILTER,
        )) {
            assertEquals("variation $variation", FieldKind.TEXT, kind(InputType.TYPE_CLASS_TEXT or variation))
        }
        assertEquals(
            FieldKind.TEXT,
            kind(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES),
        )
    }

    @Test fun passwordsDatesAndUnknownFieldsAreOther() {
        assertEquals(FieldKind.OTHER, kind(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD))
        assertEquals(FieldKind.OTHER, kind(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD))
        assertEquals(FieldKind.OTHER, kind(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD))
        assertEquals(FieldKind.OTHER, kind(InputType.TYPE_CLASS_TEXT, isPassword = true))
        assertEquals(FieldKind.OTHER, kind(InputType.TYPE_CLASS_DATETIME))
        assertEquals(FieldKind.OTHER, kind(InputType.TYPE_NULL))
    }

    @Test fun wireValuesMatchTheApi() {
        assertEquals(listOf("text", "email", "url", "number", "other"), FieldKind.values().map { it.wire })
    }

    @Test fun contextKeepsThePackageAndDropsABlankOne() {
        assertEquals(
            FieldContext("com.whatsapp", FieldKind.TEXT),
            FieldContext.of("com.whatsapp", InputType.TYPE_CLASS_TEXT),
        )
        assertNull(FieldContext.of("  ", InputType.TYPE_CLASS_TEXT).app)
        assertNull(FieldContext.of(null, InputType.TYPE_CLASS_TEXT).app)
    }
}
