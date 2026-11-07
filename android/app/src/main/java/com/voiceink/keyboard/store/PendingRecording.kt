package com.voiceink.keyboard.store

import android.content.Context
import java.io.File

/**
 * The one recording waiting to be transcribed. It survives failures and process death so the
 * user can retry, and is deleted only once its text was inserted or the user discards it.
 *
 * Each entry point keeps its own: the keyboard's lives in `recordings/`, and another one, such as
 * the mic bubble, in the [subdirectory] it names.
 */
class PendingRecording(context: Context, subdirectory: String? = null) {
    private val dir = File(context.applicationContext.noBackupFilesDir, listOfNotNull("recordings", subdirectory).joinToString("/"))
        .apply { mkdirs() }

    val file: File get() = File(dir, "pending.m4a")

    fun exists(): Boolean = file.isFile && file.length() > 0

    /** A scratch file for a new recording; [keep] replaces the pending one with it. */
    fun newScratchFile(): File = File(dir, "recording.tmp").also { it.delete() }

    fun keep(scratch: File): Boolean {
        file.delete()
        return scratch.renameTo(file)
    }

    fun discard() {
        file.delete()
        File(dir, "recording.tmp").delete()
    }
}
