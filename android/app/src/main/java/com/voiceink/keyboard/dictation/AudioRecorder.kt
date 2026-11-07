package com.voiceink.keyboard.dictation

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import java.io.File
import java.io.IOException

/** Records the microphone as AAC in MP4 (`audio/mp4`), a format the Mac accepts as `m4a`. */
class AudioRecorder(private val context: Context) {
    private var recorder: MediaRecorder? = null
    private var output: File? = null

    val isRecording: Boolean get() = recorder != null

    /** Starts recording into [file]; [onLimitReached] runs on the main thread at the length cap. */
    @Throws(IOException::class, IllegalStateException::class, SecurityException::class)
    fun start(file: File, onLimitReached: () -> Unit) {
        check(recorder == null) { "Already recording" }
        val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(context) else @Suppress("DEPRECATION") MediaRecorder()
        try {
            r.setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioChannels(1)
            r.setAudioSamplingRate(16_000)
            r.setAudioEncodingBitRate(48_000)
            r.setMaxDuration(MAX_DURATION_MS)
            r.setOnInfoListener { _, what, _ ->
                if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED) onLimitReached()
            }
            r.setOutputFile(file)
            r.prepare()
            r.start()
        } catch (e: Exception) {
            r.release()
            file.delete()
            throw e
        }
        recorder = r
        output = file
    }

    /** Stops and returns the finished file, or null when nothing usable was recorded. */
    fun stop(): File? {
        val r = recorder ?: return null
        val file = output
        recorder = null
        output = null
        val ok = try {
            r.stop()
            true
        } catch (_: RuntimeException) {
            // Thrown when stop() follows start() too quickly for any audio to be written.
            false
        } finally {
            r.release()
        }
        if (!ok || file == null || file.length() == 0L) {
            file?.delete()
            return null
        }
        return file
    }

    private companion object {
        const val MAX_DURATION_MS = 10 * 60 * 1000
    }
}
