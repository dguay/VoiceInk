package com.voiceink.keyboard.dictation

import com.voiceink.keyboard.api.ApiError
import com.voiceink.keyboard.offline.PhoneFailure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TranscriptionRouteTest {
    @Test fun aReachableMacStaysTheEngineWhenOfflineModeIsOff() {
        for (phoneReady in listOf(true, false)) {
            assertEquals(Engine.MAC, TranscriptionRoute.engine(paired = true, offlineMode = false, phoneReady = phoneReady))
        }
    }

    @Test fun offlineModeSendsEveryRecordingToThePhone() {
        assertEquals(Engine.PHONE, TranscriptionRoute.engine(paired = true, offlineMode = true, phoneReady = true))
        assertEquals(Engine.PHONE, TranscriptionRoute.engine(paired = false, offlineMode = true, phoneReady = true))
    }

    @Test fun offlineModeWithoutTheModelNeverFallsBackToTheMac() {
        assertNull(TranscriptionRoute.engine(paired = true, offlineMode = true, phoneReady = false))
        assertEquals(
            DictationState.NeedsOfflineModel,
            TranscriptionRoute.blocker(paired = true, offlineMode = true, phoneReady = false, hasMicrophone = true),
        )
    }

    @Test fun withoutAMacTheDownloadedModelTranscribes() {
        assertEquals(Engine.PHONE, TranscriptionRoute.engine(paired = false, offlineMode = false, phoneReady = true))
        assertNull(TranscriptionRoute.blocker(paired = false, offlineMode = false, phoneReady = true, hasMicrophone = true))
    }

    @Test fun withNeitherAMacNorTheModelPairingIsAsked() {
        assertNull(TranscriptionRoute.engine(paired = false, offlineMode = false, phoneReady = false))
        assertEquals(
            DictationState.NotPaired,
            TranscriptionRoute.blocker(paired = false, offlineMode = false, phoneReady = false, hasMicrophone = false),
        )
    }

    @Test fun theMicrophoneIsAskedForOnceAnEngineIsAvailable() {
        assertEquals(
            DictationState.NeedsMicrophone,
            TranscriptionRoute.blocker(paired = false, offlineMode = false, phoneReady = true, hasMicrophone = false),
        )
    }

    @Test fun onlyAnUnreachableMacFallsBackAutomaticallyAndOnlyWhenAllowed() {
        assertTrue(TranscriptionRoute.fallBackAutomatically(ApiError.Unreachable, autoFallback = true, phoneReady = true))
        assertFalse(TranscriptionRoute.fallBackAutomatically(ApiError.Unreachable, autoFallback = false, phoneReady = true))
        assertFalse(TranscriptionRoute.fallBackAutomatically(ApiError.Unreachable, autoFallback = true, phoneReady = false))
        val otherErrors = listOf(
            ApiError.Unauthorized,
            ApiError.NoModelSelected(null),
            ApiError.TranscriptionFailed(null),
            ApiError.Server(500, null, null),
            ApiError.InvalidResponse("bad json"),
        )
        for (error in otherErrors) {
            assertFalse("$error must stay on the Mac path", TranscriptionRoute.fallBackAutomatically(error, autoFallback = true, phoneReady = true))
        }
    }

    @Test fun anUnreachableKeptRecordingOffersThePhoneWhenTheModelIsReady() {
        val unreachable = DictationState.Kept(ApiError.Unreachable)

        assertTrue(TranscriptionRoute.offersPhone(unreachable, phoneReady = true))
        assertFalse(TranscriptionRoute.offersPhone(unreachable, phoneReady = false))
        assertFalse(TranscriptionRoute.offersPhone(DictationState.Kept(ApiError.Unauthorized), phoneReady = true))
        assertFalse(TranscriptionRoute.offersPhone(DictationState.Kept(null), phoneReady = true))
        assertFalse(TranscriptionRoute.offersPhone(DictationState.Idle, phoneReady = true))
    }

    @Test fun aPhoneFailureKeepsTheRecordingForRetry() {
        assertEquals(
            DictationState.Kept(null, KeptReason.PHONE_MODEL_MISSING),
            TranscriptionRoute.stateAfterPhoneFailure(PhoneFailure.MODEL_MISSING),
        )
        for (failure in listOf(PhoneFailure.AUDIO_UNREADABLE, PhoneFailure.ENGINE_FAILED)) {
            assertEquals(DictationState.Kept(null, KeptReason.PHONE_FAILED), TranscriptionRoute.stateAfterPhoneFailure(failure))
        }
    }

    @Test fun textTypedFromThePhoneIsMarkedAsLocal() {
        assertEquals(
            DictationState.InsertedOnPhone,
            TranscriptionRoute.stateAfterPhoneDelivery(TextDelivery.Outcome.INSERTED, "Hello"),
        )
    }

    @Test fun phoneTextTheFieldRejectsCanStillBeCopied() {
        val state = TranscriptionRoute.stateAfterPhoneDelivery(TextDelivery.Outcome.REJECTED, "Hello")

        assertEquals(DictationState.Kept(null, KeptReason.REJECTED, text = "Hello"), state)
        assertTrue(CopyFallback.isAvailable(state))
        assertEquals(DictationState.NoSpeech, TranscriptionRoute.stateAfterPhoneDelivery(TextDelivery.Outcome.EMPTY, ""))
        assertEquals(
            DictationState.Kept(null, KeptReason.FIELD_CHANGED),
            TranscriptionRoute.stateAfterPhoneDelivery(TextDelivery.Outcome.FIELD_CHANGED, "Hello"),
        )
    }
}
