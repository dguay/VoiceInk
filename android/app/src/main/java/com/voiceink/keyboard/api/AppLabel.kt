package com.voiceink.keyboard.api

import android.content.pm.PackageManager
import android.os.Build

/** The readable name of the app being typed into, sent to the Mac as `appName` (docs/phone-dictation-api.md). */
object AppLabel {
    /** Longest name sent, in UTF-16 code units; the Mac ignores longer ones. */
    const val MAX_LENGTH = 100

    /** The launcher label of [packageName], or null when the app is not visible to us or has no usable label. */
    fun of(packageManager: PackageManager, packageName: CharSequence?): String? {
        val pkg = packageName?.toString()?.takeIf { it.isNotBlank() } ?: return null
        val label = try {
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getApplicationInfo(pkg, PackageManager.ApplicationInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                packageManager.getApplicationInfo(pkg, 0)
            }
            packageManager.getApplicationLabel(info).toString()
        } catch (_: PackageManager.NameNotFoundException) {
            return null
        }
        return clean(label, pkg)
    }

    /** [label] trimmed, or null when it is blank, too long, has control characters or only repeats [packageName]. */
    fun clean(label: CharSequence?, packageName: String?): String? {
        val value = label?.toString()?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        if (value.length > MAX_LENGTH || value.any { Character.isISOControl(it) }) return null
        return value.takeIf { it != packageName }
    }
}
