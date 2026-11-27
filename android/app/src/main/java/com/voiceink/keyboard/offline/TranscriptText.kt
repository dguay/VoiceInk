package com.voiceink.keyboard.offline

/** Turns Whisper's raw output into the text to type. */
internal object TranscriptText {
    // Whisper marks non-speech as [BLANK_AUDIO], [Music], (silence), *sighs* and the like.
    private val bracketed = Regex("""\[[^\]]*]""")
    private val annotationOnly = Regex("""^\s*(\([^)]*\)|\*[^*]*\*)\s*$""")
    private val spaces = Regex("""\s+""")

    fun clean(raw: String): String {
        val withoutTags = bracketed.replace(raw, " ")
        if (annotationOnly.matches(withoutTags)) return ""
        return spaces.replace(withoutTags, " ").trim()
    }
}
