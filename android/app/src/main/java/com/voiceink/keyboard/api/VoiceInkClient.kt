package com.voiceink.keyboard.api

import org.json.JSONException
import org.json.JSONObject
import com.voiceink.keyboard.update.AppUpdateInfo
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

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
    // Between two chunks of the APK download, not for the whole download.
    private val downloadReadTimeoutMs: Int = 30_000,
) {
    fun status(pairing: Pairing, preferredHost: String? = null): ApiResult<MacStatus> =
        request(pairing, preferredHost, "/v1/status", "GET", statusReadTimeoutMs, body = null, ::parseStatus)

    fun transcribe(
        pairing: Pairing,
        audio: File,
        contentType: String = "audio/mp4",
        preferredHost: String? = null,
        field: FieldContext? = null,
    ): ApiResult<Transcription> =
        request(pairing, preferredHost, transcribePath(field), "POST", transcribeReadTimeoutMs, Body(audio, contentType), ::parseTranscription)

    /**
     * `POST /v1/corrections`: what became of a dictation in its field, so Auto-Learn on the Mac
     * learns from the user's corrections. Success means the Mac accepted it (it ignores it while
     * Auto-Learn is off).
     */
    fun submitCorrection(pairing: Pairing, snapshot: CorrectionSnapshot, preferredHost: String? = null): ApiResult<Unit> {
        val json = snapshot.toJson().toByteArray(Charsets.UTF_8)
        val body = Body("application/json", json.size.toLong()) { it.write(json) }
        return request(pairing, preferredHost, "/v1/corrections", "POST", statusReadTimeoutMs, body, ::parseCorrection)
    }

    /**
     * `GET /v1/app-update`: the APK the Mac offers. A Mac without one answers `404
     * app_update_unavailable`, reported as [ApiError.Server].
     */
    fun appUpdate(pairing: Pairing, preferredHost: String? = null): ApiResult<AppUpdateInfo> =
        request(pairing, preferredHost, APP_UPDATE_PATH, "GET", statusReadTimeoutMs, body = null, ::parseAppUpdate)

    /**
     * `GET /v1/app-update/apk` into [destination]. At most [maxBytes] + 1 bytes are written, so a
     * longer download is caught by the size check without filling the phone's storage. The caller
     * checks the file against the advertised size and hash (see `DownloadCheck`).
     */
    fun downloadAppUpdate(
        pairing: Pairing,
        destination: File,
        maxBytes: Long,
        preferredHost: String? = null,
    ): ApiResult<Unit> = request(
        pairing, preferredHost, APP_UPDATE_APK_PATH, "GET", downloadReadTimeoutMs, body = null,
        accept = APK_CONTENT_TYPE,
    ) { connection, host ->
        val status = connection.responseCode
        if (status != HttpURLConnection.HTTP_OK) {
            val errorBody = connection.errorStream?.use(::readUtf8).orEmpty()
            return@request ApiResult.Failure(mapError(status, errorBody))
        }
        connection.inputStream.use { input -> destination.outputStream().use { copyAtMost(input, it, maxBytes + 1) } }
        ApiResult.Success(Unit, host)
    }

    private class Body(val contentType: String, val length: Long, val write: (OutputStream) -> Unit) {
        constructor(file: File, contentType: String) :
            this(contentType, file.length(), { out -> file.inputStream().use { it.copyTo(out) } })
    }

    private fun <T> request(
        pairing: Pairing,
        preferredHost: String?,
        path: String,
        method: String,
        readTimeoutMs: Int,
        body: Body?,
        parse: (JSONObject) -> T,
    ): ApiResult<T> = request(pairing, preferredHost, path, method, readTimeoutMs, body) { connection, host ->
        exchange(connection, body, parse, host)
    }

    /** Sends one request; [handle] reads the response of the first host that accepted the connection. */
    private fun <T> request(
        pairing: Pairing,
        preferredHost: String?,
        path: String,
        method: String,
        readTimeoutMs: Int,
        body: Body?,
        accept: String = "application/json",
        handle: (HttpURLConnection, String) -> ApiResult<T>,
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
                    setRequestProperty("Accept", accept)
                    if (body != null) {
                        doOutput = true
                        setRequestProperty("Content-Type", body.contentType)
                        // Fixed length: sends Content-Length (no chunking) and rules out silent replays.
                        setFixedLengthStreamingMode(body.length)
                    }
                    connect()
                }
            } catch (_: IOException) {
                continue // This host is not reachable; try the next one.
            } catch (_: IllegalArgumentException) {
                continue
            }

            return try {
                handle(connection, host)
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
            connection.outputStream.use(body.write)
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
        const val APP_UPDATE_PATH = "/v1/app-update"
        const val APP_UPDATE_APK_PATH = "/v1/app-update/apk"
        const val APK_CONTENT_TYPE = "application/vnd.android.package-archive"

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

        /** `/v1/transcribe` with the optional `app`, `appName` and `field` query parameters for [field]. */
        internal fun transcribePath(field: FieldContext?): String {
            if (field == null) return "/v1/transcribe"
            val query = listOfNotNull(
                field.app?.let { "app=" + encodeQueryValue(it) },
                field.appName?.takeIf { field.app != null }?.let { "appName=" + encodeQueryValue(it) },
                "field=" + field.field.wire,
            )
            return "/v1/transcribe?" + query.joinToString("&")
        }

        /** Percent-encodes a query value, with spaces as `%20` (the Mac does not read `+` as a space). */
        private fun encodeQueryValue(value: String): String = URLEncoder.encode(value, "UTF-8").replace("+", "%20")

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

        private fun parseCorrection(json: JSONObject) {
            if (json.optString("status") != "accepted") throw ContractException("Correction was not accepted")
        }

        private fun parseAppUpdate(json: JSONObject): AppUpdateInfo {
            val versionCode = (json.opt("versionCode") as? Number)?.toLong()?.takeIf { it > 0 }
                ?: throw ContractException("Missing versionCode")
            val versionName = json.optStringOrNull("versionName")?.takeIf { it.isNotBlank() }
                ?: throw ContractException("Missing versionName")
            val size = (json.opt("size") as? Number)?.toLong()?.takeIf { it > 0 }
                ?: throw ContractException("Missing size")
            val sha256 = json.optStringOrNull("sha256")?.lowercase()?.takeIf { SHA256_HEX.matches(it) }
                ?: throw ContractException("Missing sha256")
            return AppUpdateInfo(versionCode, versionName, size, sha256)
        }

        private val SHA256_HEX = Regex("[0-9a-f]{64}")

        /** Copies at most [limit] bytes. */
        private fun copyAtMost(input: InputStream, output: OutputStream, limit: Long) {
            val buffer = ByteArray(64 * 1024)
            var copied = 0L
            while (copied < limit) {
                val n = input.read(buffer, 0, minOf(buffer.size.toLong(), limit - copied).toInt())
                if (n < 0) break
                output.write(buffer, 0, n)
                copied += n
            }
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
