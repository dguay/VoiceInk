package com.voiceink.keyboard.update

import com.voiceink.keyboard.api.ApiResult
import java.io.File
import java.security.MessageDigest

/** `GET /v1/app-update`: the VoiceInk Keyboard APK bundled in the paired Mac's VoiceInk app. */
data class AppUpdateInfo(
    val versionCode: Long,
    val versionName: String,
    /** Size of the APK in bytes. */
    val size: Long,
    /** Lower-case hex SHA-256 of the APK. */
    val sha256: String,
)

/** Whether the Mac's APK is worth offering. Pure, so it is unit-tested. */
object AppUpdateOffer {
    /**
     * The update to offer, or null: only a strictly greater `versionCode` than the installed one
     * is offered. The same or an older version, a missing APK (`404`) or any failure offers nothing.
     */
    fun from(installedVersionCode: Long, response: ApiResult<AppUpdateInfo>): AppUpdateInfo? {
        val info = (response as? ApiResult.Success)?.value ?: return null
        return info.takeIf { it.versionCode > installedVersionCode }
    }
}

/** Checks a downloaded APK against what the Mac advertised, before anything is installed. */
object DownloadCheck {
    enum class Result { MATCHES, WRONG_SIZE, WRONG_HASH }

    fun verify(file: File, expected: AppUpdateInfo): Result {
        if (!file.isFile || file.length() != expected.size) return Result.WRONG_SIZE
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
            }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        return if (actual.equals(expected.sha256.trim(), ignoreCase = true)) Result.MATCHES else Result.WRONG_HASH
    }
}
