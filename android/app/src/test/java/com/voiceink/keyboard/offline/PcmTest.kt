package com.voiceink.keyboard.offline

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class PcmTest {
    private fun le16(vararg values: Int) = ByteArray(values.size * 2).also { bytes ->
        values.forEachIndexed { i, v ->
            bytes[2 * i] = (v and 0xff).toByte()
            bytes[2 * i + 1] = (v shr 8).toByte()
        }
    }

    @Test fun monoSixteenBitBecomesFloatsInRange() {
        val pcm = le16(0, 16384, -32768, 32767)

        assertArrayEquals(floatArrayOf(0f, 0.5f, -1f, 32767 / 32768f), Pcm.toMonoFloats(pcm, pcm.size, 1), 1e-6f)
    }

    @Test fun stereoIsAveragedToMono() {
        val pcm = le16(16384, 0, -16384, -16384)

        assertArrayEquals(floatArrayOf(0.25f, -0.5f), Pcm.toMonoFloats(pcm, pcm.size, 2), 1e-6f)
    }

    @Test fun aTrailingPartialFrameIsIgnored() {
        val pcm = le16(100, 200, 300)

        assertEquals(1, Pcm.toMonoFloats(pcm, pcm.size, 2).size)
    }

    @Test fun sixteenKilohertzIsLeftAsIs() {
        val samples = floatArrayOf(0.1f, 0.2f)

        assertSame(samples, Pcm.resample(samples, 16_000))
    }

    @Test fun otherRatesAreResampledToSixteenKilohertz() {
        val oneSecondAt48k = FloatArray(48_000) { 0.5f }

        val resampled = Pcm.resample(oneSecondAt48k, 48_000)

        assertEquals(16_000, resampled.size)
        resampled.forEach { assertEquals(0.5f, it, 1e-6f) }
    }

    @Test fun shortRecordingsArePaddedWithSilence() {
        val padded = Pcm.padToAtLeast(floatArrayOf(0.3f), minSeconds = 1.0)

        assertEquals(16_000, padded.size)
        assertEquals(0.3f, padded[0], 0f)
        assertEquals(0f, padded.last(), 0f)
        val long = FloatArray(20_000)
        assertSame(long, Pcm.padToAtLeast(long, minSeconds = 1.0))
    }
}
