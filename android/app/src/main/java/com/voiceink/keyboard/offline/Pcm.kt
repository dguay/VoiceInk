package com.voiceink.keyboard.offline

import kotlin.math.roundToInt

/** Pure conversions from decoded PCM to the 16 kHz mono floats Whisper expects. */
internal object Pcm {
    const val WHISPER_RATE = 16_000

    /** Little-endian 16-bit [pcm] with [channels] interleaved channels, averaged to mono floats in -1..1. */
    fun toMonoFloats(pcm: ByteArray, length: Int, channels: Int): FloatArray {
        require(channels >= 1) { "channels must be at least 1" }
        val frames = length / (2 * channels)
        val out = FloatArray(frames)
        var i = 0
        for (frame in 0 until frames) {
            var sum = 0
            for (c in 0 until channels) {
                val lo = pcm[i].toInt() and 0xff
                val hi = pcm[i + 1].toInt()
                sum += (hi shl 8) or lo
                i += 2
            }
            out[frame] = sum / (channels * 32768f)
        }
        return out
    }

    /** Linear resampling from [fromRate] to [toRate]; returns [samples] unchanged when the rates match. */
    fun resample(samples: FloatArray, fromRate: Int, toRate: Int = WHISPER_RATE): FloatArray {
        require(fromRate > 0 && toRate > 0) { "rates must be positive" }
        if (fromRate == toRate || samples.isEmpty()) return samples
        val outLength = (samples.size.toLong() * toRate / fromRate).toInt().coerceAtLeast(1)
        val step = fromRate.toDouble() / toRate
        return FloatArray(outLength) { i ->
            val position = i * step
            val index = position.toInt().coerceAtMost(samples.size - 1)
            val next = (index + 1).coerceAtMost(samples.size - 1)
            val fraction = (position - index).toFloat()
            samples[index] + (samples[next] - samples[index]) * fraction
        }
    }

    /**
     * Pads [samples] with trailing silence to at least [minSeconds]: whisper.cpp ignores input
     * shorter than one second.
     */
    fun padToAtLeast(samples: FloatArray, minSeconds: Double): FloatArray {
        val minLength = (minSeconds * WHISPER_RATE).roundToInt()
        return if (samples.size >= minLength) samples else samples.copyOf(minLength)
    }
}
