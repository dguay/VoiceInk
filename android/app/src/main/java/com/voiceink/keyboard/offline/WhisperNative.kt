package com.voiceink.keyboard.offline

/** The JNI bridge to whisper.cpp in `libvoiceink_whisper.so` (src/main/cpp). */
internal object WhisperNative {
    /** False when the library could not be loaded, for example on an ABI the APK does not ship. */
    val available: Boolean by lazy {
        try {
            System.loadLibrary("voiceink_whisper")
            true
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    /** Loads the ggml model at [modelPath]; 0 when it could not be loaded. */
    external fun initContext(modelPath: String): Long

    external fun freeContext(handle: Long)

    /** Transcribes 16 kHz mono [samples] in -1..1; the UTF-8 text, or null when Whisper failed. */
    external fun transcribe(handle: Long, samples: FloatArray, threads: Int): ByteArray?
}
