package com.voiceink.keyboard.offline

import android.content.Context
import android.content.SharedPreferences

/** The user's choices for on-device transcription, shared by the setup screen, the keyboard and the bubble. */
internal class OfflineSettings(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Always transcribe on the phone, even when the Mac is reachable. */
    var offlineMode: Boolean
        get() = prefs.getBoolean(KEY_OFFLINE_MODE, false)
        set(value) = prefs.edit().putBoolean(KEY_OFFLINE_MODE, value).apply()

    /** Transcribe on the phone, without asking, when the Mac is unreachable. */
    var autoFallback: Boolean
        get() = prefs.getBoolean(KEY_AUTO_FALLBACK, false)
        set(value) = prefs.edit().putBoolean(KEY_AUTO_FALLBACK, value).apply()

    /** The model may download over mobile data; Wi-Fi (unmetered networks) only otherwise. */
    var allowMobileData: Boolean
        get() = prefs.getBoolean(KEY_ALLOW_MOBILE_DATA, false)
        set(value) = prefs.edit().putBoolean(KEY_ALLOW_MOBILE_DATA, value).apply()

    fun registerListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) =
        prefs.registerOnSharedPreferenceChangeListener(listener)

    fun unregisterListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) =
        prefs.unregisterOnSharedPreferenceChangeListener(listener)

    private companion object {
        const val PREFS = "offline_settings"
        const val KEY_OFFLINE_MODE = "offline_mode"
        const val KEY_AUTO_FALLBACK = "auto_fallback"
        const val KEY_ALLOW_MOBILE_DATA = "allow_mobile_data"
    }
}
