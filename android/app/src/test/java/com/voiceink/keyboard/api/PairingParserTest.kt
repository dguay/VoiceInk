package com.voiceink.keyboard.api

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingParserTest {
    private val token = "3q2-7wL2abcdefghijklmnopqrstuvwxyz0123456789"

    @Test fun parsesTheQrPayloadVoiceInkShows() {
        val raw = """{"hosts":["192.168.1.20","100.101.102.103"],"name":"David's MacBook Pro","port":47821,"token":"$token","v":1}"""

        assertEquals(
            PairingInput.Valid(Pairing("David's MacBook Pro", listOf("192.168.1.20", "100.101.102.103"), 47821, token)),
            PairingParser.parseQrCode(raw),
        )
    }

    @Test fun rejectsOtherQrCodes() {
        assertEquals(PairingInput.Invalid(PairingInput.Reason.NOT_A_VOICEINK_CODE), PairingParser.parseQrCode("https://example.com"))
        assertEquals(PairingInput.Invalid(PairingInput.Reason.NOT_A_VOICEINK_CODE), PairingParser.parseQrCode("""{"a":1}"""))
        assertEquals(
            PairingInput.Invalid(PairingInput.Reason.UNSUPPORTED_VERSION),
            PairingParser.parseQrCode("""{"hosts":["1.2.3.4"],"port":1,"token":"t","v":2}"""),
        )
        assertEquals(
            PairingInput.Invalid(PairingInput.Reason.MISSING_ADDRESS),
            PairingParser.parseQrCode("""{"hosts":[],"port":47821,"token":"t","v":1}"""),
        )
    }

    @Test fun manualEntryAcceptsSeveralHostsAndInlinePort() {
        assertEquals(
            PairingInput.Valid(Pairing("192.168.1.20", listOf("192.168.1.20", "100.101.102.103"), 50000, token)),
            PairingParser.parseManual(" 192.168.1.20, 100.101.102.103:50000 ", "", " $token "),
        )
    }

    @Test fun manualEntryDefaultsPortAndExplicitPortWins() {
        val defaulted = PairingParser.parseManual("mac.tailnet.ts.net", "", token) as PairingInput.Valid
        assertEquals(Pairing.DEFAULT_PORT, defaulted.pairing.port)

        val explicit = PairingParser.parseManual("http://10.0.2.2:1234/", "47821", token) as PairingInput.Valid
        assertEquals(listOf("10.0.2.2"), explicit.pairing.hosts)
        assertEquals(47821, explicit.pairing.port)
    }

    @Test fun manualEntryReportsWhatIsWrong() {
        assertEquals(PairingInput.Invalid(PairingInput.Reason.MISSING_ADDRESS), PairingParser.parseManual("  ", "", token))
        assertEquals(PairingInput.Invalid(PairingInput.Reason.MISSING_TOKEN), PairingParser.parseManual("10.0.0.2", "", " "))
        assertEquals(PairingInput.Invalid(PairingInput.Reason.BAD_PORT), PairingParser.parseManual("10.0.0.2", "99999", token))
        assertEquals(PairingInput.Invalid(PairingInput.Reason.BAD_PORT), PairingParser.parseManual("10.0.0.2:abc", "", token))
        assertEquals(PairingInput.Invalid(PairingInput.Reason.BAD_ADDRESS), PairingParser.parseManual("10.0.0.2/path", "", token))
    }

    @Test fun pairingNeverPrintsItsToken() {
        val text = Pairing("Mac", listOf("1.2.3.4"), 1, token).toString()
        assertFalse(text.contains(token))
        assertTrue(text.contains("redacted"))
    }
}
