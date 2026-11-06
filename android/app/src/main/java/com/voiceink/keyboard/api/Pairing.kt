package com.voiceink.keyboard.api

import org.json.JSONException
import org.json.JSONObject

/** How to reach one paired Mac. [hosts] are tried in order, as the QR code lists them. */
data class Pairing(
    val name: String,
    val hosts: List<String>,
    val port: Int,
    val token: String,
) {
    init {
        require(hosts.isNotEmpty()) { "At least one host is required" }
        require(port in 1..65535) { "Port out of range" }
        require(token.isNotEmpty()) { "Token is required" }
    }

    override fun toString(): String = "Pairing(name=$name, hosts=$hosts, port=$port, token=<redacted>)"

    companion object {
        const val DEFAULT_PORT = 47821
        const val API_VERSION = 1
    }
}

sealed interface PairingInput {
    data class Valid(val pairing: Pairing) : PairingInput
    data class Invalid(val reason: Reason) : PairingInput

    enum class Reason { NOT_A_VOICEINK_CODE, UNSUPPORTED_VERSION, MISSING_ADDRESS, BAD_ADDRESS, BAD_PORT, MISSING_TOKEN }
}

object PairingParser {
    // A host is an IPv4 address or a DNS name; the Mac advertises IPv4 only.
    private val hostPattern = Regex("^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$")

    /** Parses the JSON object VoiceInk encodes in its pairing QR code. */
    fun parseQrCode(raw: String): PairingInput {
        val json = try {
            JSONObject(raw.trim())
        } catch (_: JSONException) {
            return PairingInput.Invalid(PairingInput.Reason.NOT_A_VOICEINK_CODE)
        }
        if (!json.has("v") || !json.has("hosts") || !json.has("token")) {
            return PairingInput.Invalid(PairingInput.Reason.NOT_A_VOICEINK_CODE)
        }
        if (json.optInt("v", -1) != Pairing.API_VERSION) {
            return PairingInput.Invalid(PairingInput.Reason.UNSUPPORTED_VERSION)
        }
        val hostsJson = json.optJSONArray("hosts")
            ?: return PairingInput.Invalid(PairingInput.Reason.NOT_A_VOICEINK_CODE)
        val hosts = (0 until hostsJson.length()).mapNotNull { hostsJson.optString(it, "").trim().ifEmpty { null } }
        val port = if (json.has("port")) json.optInt("port", -1) else Pairing.DEFAULT_PORT
        val name = json.optString("name", "").trim()
        return validate(name, hosts, port, json.optString("token", ""))
    }

    /**
     * Parses manually typed values. [addresses] holds one or more hosts separated by commas or
     * whitespace; a host may carry its own `:port`, which then overrides [port] when it is blank.
     */
    fun parseManual(addresses: String, port: String, token: String): PairingInput {
        val entries = addresses.split(',', ' ', '\n', '\t').map { it.trim() }.filter { it.isNotEmpty() }
        if (entries.isEmpty()) return PairingInput.Invalid(PairingInput.Reason.MISSING_ADDRESS)

        var inlinePort: Int? = null
        val hosts = mutableListOf<String>()
        for (entry in entries) {
            val withoutScheme = entry.removePrefix("http://").trimEnd('/')
            val colon = withoutScheme.lastIndexOf(':')
            if (colon >= 0) {
                val p = withoutScheme.substring(colon + 1).toIntOrNull()
                    ?: return PairingInput.Invalid(PairingInput.Reason.BAD_PORT)
                inlinePort = p
                hosts += withoutScheme.substring(0, colon)
            } else {
                hosts += withoutScheme
            }
        }
        val resolvedPort = when {
            port.isNotBlank() -> port.trim().toIntOrNull() ?: return PairingInput.Invalid(PairingInput.Reason.BAD_PORT)
            inlinePort != null -> inlinePort
            else -> Pairing.DEFAULT_PORT
        }
        return validate(hosts.first(), hosts, resolvedPort, token)
    }

    private fun validate(name: String, hosts: List<String>, port: Int, token: String): PairingInput {
        if (hosts.isEmpty()) return PairingInput.Invalid(PairingInput.Reason.MISSING_ADDRESS)
        if (hosts.any { !hostPattern.matches(it) }) return PairingInput.Invalid(PairingInput.Reason.BAD_ADDRESS)
        if (port !in 1..65535) return PairingInput.Invalid(PairingInput.Reason.BAD_PORT)
        val trimmedToken = token.trim()
        if (trimmedToken.isEmpty()) return PairingInput.Invalid(PairingInput.Reason.MISSING_TOKEN)
        val distinctHosts = hosts.distinct()
        return PairingInput.Valid(Pairing(name.ifEmpty { distinctHosts.first() }, distinctHosts, port, trimmedToken))
    }
}
