package com.voiceink.keyboard.update

import com.voiceink.keyboard.api.ApiError
import com.voiceink.keyboard.api.ApiResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.security.MessageDigest

class AppUpdateTest {
    @get:Rule val tmp = TemporaryFolder()

    private val apk = ByteArray(10_000) { (it * 31 % 256).toByte() }
    private fun sha256(bytes: ByteArray) =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun info(versionCode: Long = 120, size: Long = apk.size.toLong(), sha256: String = sha256(apk)) =
        AppUpdateInfo(versionCode, "0.1.$versionCode-abcdef123456", size, sha256)

    private fun mac(info: AppUpdateInfo) = ApiResult.Success(info, "127.0.0.1")

    // Version comparison

    @Test fun aNewerVersionIsOffered() {
        val newer = info(versionCode = 121)
        assertEquals(newer, AppUpdateOffer.from(120, mac(newer)))
    }

    @Test fun theSameVersionIsNotOffered() {
        assertNull(AppUpdateOffer.from(120, mac(info(versionCode = 120))))
    }

    @Test fun anOlderVersionIsNotOffered() {
        assertNull(AppUpdateOffer.from(120, mac(info(versionCode = 119))))
    }

    @Test fun aMacWithoutAnAPKOrUnreachableOffersNothing() {
        val missing = ApiResult.Failure(ApiError.Server(404, "app_update_unavailable", "none"))
        assertNull(AppUpdateOffer.from(120, missing))
        assertNull(AppUpdateOffer.from(120, ApiResult.Failure(ApiError.Unreachable)))
        assertNull(AppUpdateOffer.from(120, ApiResult.Failure(ApiError.InvalidResponse("x"))))
    }

    // Download check

    @Test fun aMatchingDownloadPasses() {
        val file = tmp.newFile("ok.apk").apply { writeBytes(apk) }
        assertEquals(DownloadCheck.Result.MATCHES, DownloadCheck.verify(file, info()))
        assertEquals(DownloadCheck.Result.MATCHES, DownloadCheck.verify(file, info(sha256 = sha256(apk).uppercase())))
    }

    @Test fun aTruncatedOrLongerDownloadIsRejected() {
        val truncated = tmp.newFile("short.apk").apply { writeBytes(apk.copyOf(apk.size - 1)) }
        assertEquals(DownloadCheck.Result.WRONG_SIZE, DownloadCheck.verify(truncated, info()))
        val longer = tmp.newFile("long.apk").apply { writeBytes(apk + byteArrayOf(0)) }
        assertEquals(DownloadCheck.Result.WRONG_SIZE, DownloadCheck.verify(longer, info()))
        assertEquals(DownloadCheck.Result.WRONG_SIZE, DownloadCheck.verify(tmp.root.resolve("missing.apk"), info()))
    }

    @Test fun aCorruptedDownloadOfTheRightSizeIsRejected() {
        val corrupted = apk.copyOf().also { it[5000] = (it[5000] + 1).toByte() }
        val file = tmp.newFile("bad.apk").apply { writeBytes(corrupted) }
        assertEquals(DownloadCheck.Result.WRONG_HASH, DownloadCheck.verify(file, info()))
    }
}
