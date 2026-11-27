package com.voiceink.keyboard.offline

/**
 * The one on-device speech model the app offers: whisper.cpp's multilingual Whisper base,
 * quantized to 5 bits, pinned to a Hugging Face revision and checked against its SHA-256 before
 * it is used.
 */
internal object OfflineModel {
    const val FILE_NAME = "ggml-base-q5_1.bin"
    const val URL =
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base-q5_1.bin"
    const val SIZE_BYTES = 59_707_625L
    const val SHA256 = "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"

    /** The download is first written outside the app's private storage, then copied in. */
    const val FREE_SPACE_NEEDED = 2 * SIZE_BYTES
}
