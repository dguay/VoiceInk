package com.voiceink.keyboard.offline

/** How many threads Whisper runs on; pure, so the core heuristics are unit-tested. */
internal object EngineThreads {
    private const val MAX = 6

    /**
     * The performance cores (those faster than the slowest tier) when [maxFrequencies] tells them
     * apart; otherwise every core but one, which stays free for the keyboard and the system.
     */
    fun count(cores: Int, maxFrequencies: List<Long>): Int {
        val slowest = maxFrequencies.minOrNull()
        val fast = if (slowest != null && maxFrequencies.size == cores) maxFrequencies.count { it > slowest } else 0
        val preferred = if (fast > 0) fast else cores - 1
        return preferred.coerceIn(1, MAX)
    }
}
