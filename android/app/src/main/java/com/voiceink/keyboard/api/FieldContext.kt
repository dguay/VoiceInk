package com.voiceink.keyboard.api

import android.text.InputType

/** The kind of field being typed into, sent to the Mac as `field` (docs/phone-dictation-api.md). */
enum class FieldKind(val wire: String) {
    TEXT("text"),
    EMAIL("email"),
    URL("url"),
    NUMBER("number"),
    OTHER("other");

    companion object {
        /** Maps an Android `inputType` (from `EditorInfo` or `AccessibilityNodeInfo`) to a field kind. */
        fun fromInputType(inputType: Int, isPassword: Boolean = false): FieldKind {
            if (isPassword) return OTHER
            return when (inputType and InputType.TYPE_MASK_CLASS) {
                InputType.TYPE_CLASS_NUMBER, InputType.TYPE_CLASS_PHONE -> NUMBER
                InputType.TYPE_CLASS_TEXT -> when (inputType and InputType.TYPE_MASK_VARIATION) {
                    InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
                    InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS -> EMAIL
                    InputType.TYPE_TEXT_VARIATION_URI -> URL
                    InputType.TYPE_TEXT_VARIATION_PASSWORD,
                    InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
                    InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD -> OTHER
                    else -> TEXT
                }
                else -> OTHER // Date and time pickers, and TYPE_NULL fields that do not say.
            }
        }
    }
}

/**
 * Where a dictation goes: the app's package name, the kind of field and, when the phone can read
 * it, the app's readable name ([appName], only sent together with [app]).
 */
data class FieldContext(val app: String?, val field: FieldKind, val appName: String? = null) {
    companion object {
        fun of(
            packageName: CharSequence?,
            inputType: Int,
            isPassword: Boolean = false,
            appName: CharSequence? = null,
        ): FieldContext {
            val app = packageName?.toString()?.takeIf { it.isNotBlank() }
            return FieldContext(
                app = app,
                field = FieldKind.fromInputType(inputType, isPassword),
                appName = app?.let { AppLabel.clean(appName, it) },
            )
        }
    }
}
