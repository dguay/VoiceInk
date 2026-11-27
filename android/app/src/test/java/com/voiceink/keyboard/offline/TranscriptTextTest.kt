package com.voiceink.keyboard.offline

import org.junit.Assert.assertEquals
import org.junit.Test

class TranscriptTextTest {
    @Test fun whisperSegmentsBecomeOneTrimmedLine() {
        assertEquals("Meet at noon. Bring the notes.", TranscriptText.clean(" Meet at noon.\n Bring the notes. "))
    }

    @Test fun nonSpeechTagsAreDropped() {
        assertEquals("", TranscriptText.clean(" [BLANK_AUDIO]"))
        assertEquals("Hello there.", TranscriptText.clean("[Music] Hello there. [BLANK_AUDIO]"))
    }

    @Test fun aRecordingOfOnlyAnAnnotationHeardNothing() {
        assertEquals("", TranscriptText.clean(" (silence) "))
        assertEquals("", TranscriptText.clean(" *sighs*"))
    }

    @Test fun parenthesesInsideSpeechAreKept() {
        assertEquals("Call me (after lunch) please.", TranscriptText.clean(" Call me (after lunch) please."))
    }
}
