package com.voiceink.keyboard.store

import android.content.Context
import com.voiceink.keyboard.api.Pairing

/** The paired Mac. The token is stored only in encrypted form. */
class PairingStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("pairing", Context.MODE_PRIVATE)
    private val box = SecretBox("voiceink-pairing-token")

    fun load(): Pairing? {
        val hosts = prefs.getString(KEY_HOSTS, null)?.split(',')?.filter { it.isNotEmpty() }.orEmpty()
        val sealed = prefs.getString(KEY_TOKEN, null) ?: return null
        val token = box.open(sealed) ?: return null
        if (hosts.isEmpty()) return null
        return runCatching {
            Pairing(prefs.getString(KEY_NAME, null) ?: hosts.first(), hosts, prefs.getInt(KEY_PORT, Pairing.DEFAULT_PORT), token)
        }.getOrNull()
    }

    fun save(pairing: Pairing, reachedHost: String, model: String?) {
        prefs.edit().apply {
            putString(KEY_NAME, pairing.name)
            putString(KEY_HOSTS, pairing.hosts.joinToString(","))
            putInt(KEY_PORT, pairing.port)
            putString(KEY_TOKEN, box.seal(pairing.token))
            putString(KEY_LAST_HOST, reachedHost)
            putString(KEY_MODEL, model)
        }.apply()
    }

    var lastHost: String?
        get() = prefs.getString(KEY_LAST_HOST, null)
        set(value) = prefs.edit().putString(KEY_LAST_HOST, value).apply()

    val model: String? get() = prefs.getString(KEY_MODEL, null)

    fun clear() = prefs.edit().clear().apply()

    private companion object {
        const val KEY_NAME = "name"
        const val KEY_HOSTS = "hosts"
        const val KEY_PORT = "port"
        const val KEY_TOKEN = "token_sealed"
        const val KEY_LAST_HOST = "last_host"
        const val KEY_MODEL = "model"
    }
}
