package com.voiceink.keyboard.offline

import android.content.Context
import android.os.SystemClock
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

/** Why a recording could not be transcribed on the phone. */
internal enum class PhoneFailure {
    /** The model is not downloaded (or was deleted). */
    MODEL_MISSING,

    /** The recording could not be decoded. */
    AUDIO_UNREADABLE,

    /** The native engine could not load the model or failed while transcribing. */
    ENGINE_FAILED,
}

internal sealed interface PhoneResult {
    data class Text(val text: String) : PhoneResult
    data class Failed(val failure: PhoneFailure) : PhoneResult
}

/**
 * Transcribes a recording on the phone with the downloaded Whisper model: raw text, without the
 * Mac's modes, dictionary, replacements or AI cleanup. One transcription runs at a time (the keyboard
 * and the bubble share the process), and the model is loaded only for the transcription.
 */
internal object OnDeviceTranscriber {
    private val lock = Mutex()

    suspend fun transcribe(context: Context, recording: File): PhoneResult = withContext(Dispatchers.Default) {
        lock.withLock {
            val model = OfflineModelStore(context).installedModel() ?: return@withLock PhoneResult.Failed(PhoneFailure.MODEL_MISSING)
            val start = SystemClock.elapsedRealtime()
            val samples = AudioDecoder.decode(recording) ?: return@withLock PhoneResult.Failed(PhoneFailure.AUDIO_UNREADABLE)
            val decoded = SystemClock.elapsedRealtime()
            if (!WhisperNative.available) return@withLock PhoneResult.Failed(PhoneFailure.ENGINE_FAILED)
            val handle = WhisperNative.initContext(model.absolutePath)
            if (handle == 0L) return@withLock PhoneResult.Failed(PhoneFailure.ENGINE_FAILED)
            val loaded = SystemClock.elapsedRealtime()
            try {
                val bytes = WhisperNative.transcribe(handle, Pcm.padToAtLeast(samples, MIN_SECONDS), threads())
                    ?: return@withLock PhoneResult.Failed(PhoneFailure.ENGINE_FAILED)
                Log.d(
                    TAG,
                    "${samples.size / Pcm.WHISPER_RATE.toFloat()} s of audio: decoded in ${decoded - start} ms, " +
                        "model loaded in ${loaded - decoded} ms, transcribed in ${SystemClock.elapsedRealtime() - loaded} ms",
                )
                PhoneResult.Text(TranscriptText.clean(String(bytes, Charsets.UTF_8)))
            } finally {
                WhisperNative.freeContext(handle)
            }
        }
    }

    /** Whisper's threads wait on each other at every step, so leave the slow cores and one core for the UI alone. */
    private fun threads(): Int = EngineThreads.count(Runtime.getRuntime().availableProcessors(), coreMaxFrequencies())

    private fun coreMaxFrequencies(): List<Long> = try {
        File("/sys/devices/system/cpu").listFiles { f -> f.name.matches(Regex("cpu\\d+")) }.orEmpty().mapNotNull {
            File(it, "cpufreq/cpuinfo_max_freq").takeIf(File::canRead)?.readText()?.trim()?.toLongOrNull()
        }
    } catch (_: Exception) {
        emptyList()
    }

    private const val TAG = "VoiceInkOffline"
    private const val MIN_SECONDS = 1.1
}
