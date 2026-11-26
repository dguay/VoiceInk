package com.voiceink.keyboard.bubble

import android.content.Context
import android.content.SharedPreferences

/**
 * The mic bubble's preferences: where the user dragged it and the apps it never appears in. The
 * position's lift is stored in dp so it keeps its size if the display density changes.
 */
class BubbleSettings(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("bubble", Context.MODE_PRIVATE)
    private val density = context.resources.displayMetrics.density

    internal var position: BubblePosition?
        get() {
            if (!prefs.contains(KEY_ACROSS) || !prefs.contains(KEY_LIFT_DP)) return null
            return BubblePosition(prefs.getFloat(KEY_ACROSS, 1f), (prefs.getFloat(KEY_LIFT_DP, 0f) * density).toInt())
        }
        set(value) {
            prefs.edit().apply {
                if (value == null) {
                    remove(KEY_ACROSS)
                    remove(KEY_LIFT_DP)
                } else {
                    putFloat(KEY_ACROSS, value.across)
                    putFloat(KEY_LIFT_DP, value.lift / density)
                }
            }.apply()
        }

    val hasCustomPosition: Boolean get() = position != null

    fun resetPosition() {
        position = null
    }

    /** Packages of the apps the bubble never appears in. */
    var excludedApps: Set<String>
        get() = prefs.getStringSet(KEY_EXCLUDED, null)?.toSet().orEmpty()
        set(value) = prefs.edit().putStringSet(KEY_EXCLUDED, value.toSet()).apply()

    /** How long the bubble stays untouched before tucking against the nearest screen edge. */
    var idleCollapse: IdleCollapseTimeout
        get() = IdleCollapseTimeout.fromSeconds(prefs.getInt(KEY_IDLE_COLLAPSE_SECONDS, 0))
        set(value) = prefs.edit().putInt(KEY_IDLE_COLLAPSE_SECONDS, value.seconds).apply()

    fun registerListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) =
        prefs.registerOnSharedPreferenceChangeListener(listener)

    fun unregisterListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) =
        prefs.unregisterOnSharedPreferenceChangeListener(listener)

    private companion object {
        const val KEY_ACROSS = "position_across"
        const val KEY_LIFT_DP = "position_lift_dp"
        const val KEY_EXCLUDED = "excluded_apps"
        const val KEY_IDLE_COLLAPSE_SECONDS = "idle_collapse_seconds"
    }
}
