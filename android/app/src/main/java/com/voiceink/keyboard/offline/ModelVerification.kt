package com.voiceink.keyboard.offline

import java.io.File
import java.io.IOException
import java.security.MessageDigest

/** Installs a downloaded model only when it matches the pinned size and SHA-256. */
internal object ModelVerification {
    enum class Result { MATCHES, WRONG_SIZE, WRONG_HASH }

    /**
     * Copies [source] to [destination] while hashing it, in one pass. The copy is written beside
     * [destination] and renamed into place only when it matches; otherwise nothing is left there.
     */
    @Throws(IOException::class)
    fun install(source: File, destination: File, size: Long, sha256: String): Result {
        if (!source.isFile || source.length() != size) return Result.WRONG_SIZE
        destination.parentFile?.mkdirs()
        val partial = File(destination.parentFile, destination.name + ".tmp")
        val digest = MessageDigest.getInstance("SHA-256")
        var copied = 0L
        try {
            source.inputStream().use { input ->
                partial.outputStream().use { output ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        digest.update(buffer, 0, n)
                        output.write(buffer, 0, n)
                        copied += n
                    }
                }
            }
            if (copied != size) return Result.WRONG_SIZE
            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            if (!actual.equals(sha256, ignoreCase = true)) return Result.WRONG_HASH
            destination.delete()
            if (!partial.renameTo(destination)) throw IOException("Could not move the model into place.")
            return Result.MATCHES
        } finally {
            partial.delete()
        }
    }
}
