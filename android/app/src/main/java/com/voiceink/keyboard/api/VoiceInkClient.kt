package com.voiceink.keyboard.api

import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

/** `GET /v1/status` on success. */
data class MacStatus(val apiVersion: Int, val model: String, val mode: String?)

/** `POST /v1/transcribe` on success. */
data class Transcription(
    val text: String,
    val id: String?,
    val durationSeconds: Double?,
    val model: String?,
    val mode: String?,
    val enhancementError: String?,
)

/** Every way a request can fail, as the keyboard and pairing screen need to tell them apart. */
sealed interface ApiError {
    /** No host accepted a connection, or the connection broke before a response arrived. */
    data object Unreachable : ApiError

    /** `401`: the token is missing, wrong or was regenerated on the Mac. Re-pair. */
    data object Unauthorized : ApiError

    /** `503 no_model_selected`. */
    data class NoModelSelected(val message: String?) : ApiError

    /** `500 transcription_failed`. */
    data class TranscriptionFailed(val message: String?) : ApiError

    /** Any other documented or undocumented error response. */
    data class Server(val httpStatus: Int, val code: String?, val message: String?) : ApiError

    /** A `200` whose body does not match the contract. */
    data class InvalidResponse(val detail: String) : ApiError
}

sealed interface ApiResult<out T> {
    /** [host] answered; try it first next time. */
    data class Success<T>(val value: T, val host: String) : ApiResult<T>
    data class Failure(val error: ApiError) : ApiResult<Nothing>
}

/**
 * Client for VoiceInk's phone dictation API v1 (docs/phone-dictation-api.md).
 *
 * Hosts are tried in order, but only while no connection has been established: once a host
 * accepts the TCP connection, a failure is reported as [ApiError.Unreachable] and the request is
 * never re-sent elsewhere, so one recording cannot be transcribed twice.
 */
class VoiceInkClient(
    private val connectTimeoutMs: Int = 4_000,
    private val statusReadTimeoutMs: Int = 15_000,
    // Transcription and AI cleanup of a long recording can take minutes.
    private val transcribeReadTimeoutMs: Int = 300_000,
) {
    fun status(pairing: Pairing, preferredHost: String? = null): ApiResult<MacStatus> =
        request(pairing, preferredHost, "/v1/status", "GET", statusReadTimeoutMs, body = null, ::parseStatus)

    fun transcribe(
        pairing: Pairing,
        audio: File,
        contentType: String = "audio/mp4",
        preferredHost: String? = null,
    ): ApiResult<Transcription> =
        request(pairing, preferredHost, "/v1/transcribe", "POST", transcribeReadTimeoutMs, Body(audio, contentType), ::parseTranscription)

    private class Body(val file: File, val contentType: String)

    private fun <T> request(
        pairing: Pairing,
        preferredHost: String?,
        path: String,
        method: String,
        readTimeoutMs: Int,
        body: Body?,
        parse: (JSONObject) -> T,
    ): ApiResult<T> {
        for (host in orderedHosts(pairing.hosts, preferredHost)) {
            val connection = try {
                (URL("http", host, pairing.port, path).openConnection() as HttpURLConnection).apply {
                    requestMethod = method
                    connectTimeout = connectTimeoutMs
                    readTimeout = readTimeoutMs
                    instanceFollowRedirects = false
                    useCaches = false
                    setRequestProperty("Authorization", "Bearer ${pairing.token}")
                    setRequestProperty("Accept", "application/json")
                    if (body != null) {
                        doOutput = true
                        setRequestProperty("Content-Type", body.contentType)
                        // Fixed length: sends Content-Length (no chunking) and rules out silent replays.
                        setFixedLengthStreamingMode(body.file.length())
                    }
                    connect()
                }
            } catch (_: IOException) {
                continue // This host is not reachable; try the next one.
            } catch (_: IllegalArgumentException) {
                continue
            }

            return try {
                exchange(connection, body, parse, host)
            } catch (_: IOException) {
                ApiResult.Failure(ApiError.Unreachable)
            } finally {
                connection.disconnect()
            }
        }
        return ApiResult.Failure(ApiError.Unreachable)
    }

    private fun <T> exchange(
        connection: HttpURLConnection,
        body: Body?,
        parse: (JSONObject) -> T,
        host: String,
    ): ApiResult<T> {
        if (body != null) {
            connection.outputStream.use { out -> body.file.inputStream().use { it.copyTo(out) } }
        }
        val status = connection.responseCode
        if (status == HttpURLConnection.HTTP_OK) {
            val text = connection.inputStream.use(::readUtf8)
            val json = try {
                JSONObject(text)
            } catch (_: JSONException) {
                return ApiResult.Failure(ApiError.InvalidResponse("Response is not a JSON object"))
            }
            return try {
                ApiResult.Success(parse(json), host)
            } catch (e: ContractException) {
                ApiResult.Failure(ApiError.InvalidResponse(e.message ?: "Unexpected response"))
            }
        }
        val errorBody = connection.errorStream?.use(::readUtf8).orEmpty()
        return ApiResult.Failure(mapError(status, errorBody))
    }

    companion object {
        private const val MAX_RESPONSE_BYTES = 1 shl 20

        /** Maps an error response to [ApiError], branching on `error.code` as the contract asks. */
        fun mapError(httpStatus: Int, body: String): ApiError {
            val error = try {
                JSONObject(body).optJSONObject("error")
            } catch (_: JSONException) {
                null
            }
            val code = error?.optStringOrNull("code")
            val message = error?.optStringOrNull("message")
            return when (code) {
                "unauthorized" -> ApiError.Unauthorized
                "no_model_selected" -> ApiError.NoModelSelected(message)
                "transcription_failed" -> ApiError.TranscriptionFailed(message)
                null -> if (httpStatus == HttpURLConnection.HTTP_UNAUTHORIZED) {
                    ApiError.Unauthorized
                } else {
                    ApiError.Server(httpStatus, null, message)
                }
                else -> ApiError.Server(httpStatus, code, message)
            }
        }

        internal fun orderedHosts(hosts: List<String>, preferred: String?): List<String> =
            if (preferred != null && preferred in hosts) listOf(preferred) + (hosts - preferred) else hosts

        private fun parseStatus(json: JSONObject): MacStatus {
            if (json.optString("status") != "ready") throw ContractException("Status is not ready")
            val model = json.optStringOrNull("model") ?: throw ContractException("Missing model")
            return MacStatus(json.optInt("apiVersion", Pairing.API_VERSION), model, json.optStringOrNull("mode"))
        }

        private fun parseTranscription(json: JSONObject): Transcription {
            if (!json.has("text") || json.get("text") !is String) throw ContractException("Missing text")
            return Transcription(
                text = json.getString("text"),
                id = json.optStringOrNull("id"),
                durationSeconds = if (json.has("durationSeconds") && !json.isNull("durationSeconds")) {
                    json.optDouble("durationSeconds")
                } else {
                    null
                },
                model = json.optStringOrNull("model"),
                mode = json.optStringOrNull("mode"),
                enhancementError = json.optStringOrNull("enhancementError"),
            )
        }

        private fun JSONObject.optStringOrNull(key: String): String? =
            if (has(key) && !isNull(key)) (opt(key) as? String) else null

        private fun readUtf8(stream: InputStream): String {
            val out = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8 * 1024)
            while (out.size() < MAX_RESPONSE_BYTES) {
                val n = stream.read(buffer, 0, minOf(buffer.size, MAX_RESPONSE_BYTES - out.size()))
                if (n < 0) break
                out.write(buffer, 0, n)
            }
            return out.toString(Charsets.UTF_8.name())
        }
    }

    private class ContractException(message: String) : Exception(message)
}
