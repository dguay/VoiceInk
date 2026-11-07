package com.voiceink.keyboard.setup

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AccessibilitySettingTest {
    private val pkg = "com.voiceink.keyboard"
    private val cls = "com.voiceink.keyboard.bubble.MicBubbleService"

    @Test fun findsTheServiceAmongOthersInEitherNameForm() {
        assertTrue(AccessibilitySetting.isEnabled("com.other/.Reader:$pkg/$cls", pkg, cls))
        assertTrue(AccessibilitySetting.isEnabled("$pkg/.bubble.MicBubbleService", pkg, cls))
    }

    @Test fun isOffWhenNotListed() {
        assertFalse(AccessibilitySetting.isEnabled(null, pkg, cls))
        assertFalse(AccessibilitySetting.isEnabled("", pkg, cls))
        assertFalse(AccessibilitySetting.isEnabled("com.other/.Reader", pkg, cls))
    }
}
