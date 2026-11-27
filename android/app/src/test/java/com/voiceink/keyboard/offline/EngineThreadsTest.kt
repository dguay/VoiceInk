package com.voiceink.keyboard.offline

import org.junit.Assert.assertEquals
import org.junit.Test

class EngineThreadsTest {
    @Test fun bigLittlePhonesUseTheirPerformanceCores() {
        val oneThreeFour = listOf(1_800_000L, 1_800_000, 1_800_000, 1_800_000, 2_400_000, 2_400_000, 2_400_000, 3_000_000)
        assertEquals(4, EngineThreads.count(8, oneThreeFour))
    }

    @Test fun identicalCoresLeaveOneFree() {
        assertEquals(3, EngineThreads.count(4, List(4) { 2_000_000L }))
        assertEquals(3, EngineThreads.count(4, emptyList()))
    }

    @Test fun theCountStaysBetweenOneAndSix() {
        assertEquals(1, EngineThreads.count(1, emptyList()))
        assertEquals(6, EngineThreads.count(12, List(4) { 1L } + List(8) { 2L }))
    }
}
