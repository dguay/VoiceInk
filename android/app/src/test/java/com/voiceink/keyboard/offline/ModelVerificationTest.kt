package com.voiceink.keyboard.offline

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.MessageDigest

class ModelVerificationTest {
    @get:Rule val folder = TemporaryFolder()

    private val content = ByteArray(300_000) { (it % 251).toByte() }
    private val sha = MessageDigest.getInstance("SHA-256").digest(content).joinToString("") { "%02x".format(it) }

    private fun source(bytes: ByteArray = content) = folder.newFile().apply { writeBytes(bytes) }
    private fun destination() = File(folder.root, "models/model.bin")

    @Test fun aMatchingDownloadIsInstalled() {
        val target = destination()

        assertEquals(ModelVerification.Result.MATCHES, ModelVerification.install(source(), target, content.size.toLong(), sha))
        assertArrayEquals(content, target.readBytes())
        assertFalse(File(target.parentFile, "model.bin.tmp").exists())
    }

    @Test fun aTruncatedDownloadInstallsNothing() {
        val target = destination()
        val truncated = source(content.copyOf(content.size - 1))

        assertEquals(ModelVerification.Result.WRONG_SIZE, ModelVerification.install(truncated, target, content.size.toLong(), sha))
        assertFalse(target.exists())
    }

    @Test fun aTamperedDownloadInstallsNothingAndLeavesNoPartialCopy() {
        val target = destination()
        val tampered = content.copyOf().also { it[1234] = (it[1234] + 1).toByte() }

        assertEquals(ModelVerification.Result.WRONG_HASH, ModelVerification.install(source(tampered), target, content.size.toLong(), sha))
        assertFalse(target.exists())
        assertFalse(File(target.parentFile, "model.bin.tmp").exists())
    }

    @Test fun aMissingDownloadIsTheWrongSize() {
        assertEquals(
            ModelVerification.Result.WRONG_SIZE,
            ModelVerification.install(File(folder.root, "absent"), destination(), content.size.toLong(), sha),
        )
    }
}
