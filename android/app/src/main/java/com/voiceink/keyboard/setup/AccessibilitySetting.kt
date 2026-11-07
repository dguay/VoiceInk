package com.voiceink.keyboard.setup

/** Reads Android's list of accessibility services the user turned on. */
internal object AccessibilitySetting {
    /**
     * Whether [enabledServices] (the colon-separated `enabled_accessibility_services` setting,
     * whose entries are `package/class` or `package/.class`) lists [packageName]/[className].
     */
    fun isEnabled(enabledServices: String?, packageName: String, className: String): Boolean =
        enabledServices.orEmpty().split(':').any { entry ->
            val pkg = entry.substringBefore('/', missingDelimiterValue = "")
            val cls = entry.substringAfter('/', missingDelimiterValue = "")
            val fullClass = if (cls.startsWith('.')) pkg + cls else cls
            pkg.equals(packageName, ignoreCase = true) && fullClass.equals(className, ignoreCase = true)
        }
}
