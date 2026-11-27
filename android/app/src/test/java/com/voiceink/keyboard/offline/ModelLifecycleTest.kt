package com.voiceink.keyboard.offline

import com.voiceink.keyboard.offline.ModelLifecycle.Action
import com.voiceink.keyboard.offline.ModelLifecycle.Download
import com.voiceink.keyboard.offline.ModelLifecycle.Pause
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelLifecycleTest {
    private fun decide(
        installed: Boolean = false,
        download: Download? = null,
        lastFailure: ModelFailure? = null,
        allowMobileData: Boolean = false,
        onUnmeteredNetwork: Boolean = true,
    ) = ModelLifecycle.decide(installed, download, lastFailure, allowMobileData, onUnmeteredNetwork)

    @Test fun nothingDownloadedIsAbsent() {
        assertEquals(ModelLifecycle.Decision(ModelState.Absent), decide())
    }

    @Test fun anInstalledModelIsReadyAndDropsAnyLeftoverDownload() {
        assertEquals(ModelLifecycle.Decision(ModelState.Ready), decide(installed = true))
        assertEquals(Action.FORGET, decide(installed = true, download = Download.Succeeded).action)
    }

    @Test fun aRunningDownloadReportsItsProgress() {
        val decision = decide(download = Download.Running(downloaded = 1_000, total = 4_000))

        assertEquals(ModelState.Downloading(1_000, 4_000, waiting = null), decision.state)
        assertEquals(Action.NONE, decision.action)
    }

    @Test fun anUnknownTotalFallsBackToTheModelSize() {
        val state = decide(download = Download.Running(downloaded = 10, total = -1)).state

        assertEquals(ModelState.Downloading(10, OfflineModel.SIZE_BYTES, waiting = null), state)
    }

    @Test fun withoutMobileDataAnyWaitForANetworkIsAWaitForWifi() {
        for (pause in listOf(Pause.QUEUED_FOR_WIFI, Pause.WAITING_FOR_NETWORK)) {
            val state = decide(download = Download.Paused(5, 10, pause), allowMobileData = false).state
            assertEquals(ModelState.Downloading(5, 10, Waiting.WIFI), state)
        }
    }

    @Test fun withMobileDataAllowedANetworkWaitIsJustANetworkWait() {
        val state = decide(download = Download.Paused(5, 10, Pause.WAITING_FOR_NETWORK), allowMobileData = true).state

        assertEquals(ModelState.Downloading(5, 10, Waiting.NETWORK), state)
    }

    @Test fun aFinishedDownloadIsVerifiedBeforeItCounts() {
        val decision = decide(download = Download.Succeeded)

        assertEquals(ModelState.Verifying, decision.state)
        assertEquals(Action.VERIFY, decision.action)
    }

    @Test fun aFailedDownloadIsRecordedAndForgotten() {
        assertEquals(
            ModelLifecycle.Decision(ModelState.Failed(ModelFailure.DOWNLOAD_FAILED), Action.FORGET, ModelFailure.DOWNLOAD_FAILED),
            decide(download = Download.Failed(noSpace = false)),
        )
        assertEquals(ModelFailure.NO_SPACE, decide(download = Download.Failed(noSpace = true)).failure)
    }

    @Test fun theLastFailureIsShownUntilTheNextAttempt() {
        assertEquals(ModelState.Failed(ModelFailure.CORRUPTED), decide(lastFailure = ModelFailure.CORRUPTED).state)
    }

    @Test fun aDownloadRemovedOutsideTheAppIsForgotten() {
        assertEquals(ModelLifecycle.Decision(ModelState.Absent, Action.FORGET), decide(download = Download.Missing))
    }

    @Test fun onlyAMatchingFileBecomesReady() {
        assertEquals(
            ModelLifecycle.Decision(ModelState.Ready, Action.FORGET),
            ModelLifecycle.afterVerification(ModelVerification.Result.MATCHES),
        )
        for (mismatch in listOf(ModelVerification.Result.WRONG_SIZE, ModelVerification.Result.WRONG_HASH)) {
            val decision = ModelLifecycle.afterVerification(mismatch)
            assertEquals(ModelState.Failed(ModelFailure.CORRUPTED), decision.state)
            assertEquals(ModelFailure.CORRUPTED, decision.failure)
        }
    }

    @Test fun wifiOnlyUnlessMobileDataIsAllowed() {
        val wifiOnly = DownloadNetworkPolicy.of(allowMobileData = false)
        assertFalse(wifiOnly.allowedOverMetered)
        assertFalse(wifiOnly.allowedOverRoaming)
        val mobile = DownloadNetworkPolicy.of(allowMobileData = true)
        assertTrue(mobile.allowedOverMetered)
        assertTrue(mobile.allowedOverRoaming)
    }

    @Test fun aPendingWifiOnlyDownloadOnMobileDataWaitsForWifi() {
        val state = decide(download = Download.Queued(null), allowMobileData = false, onUnmeteredNetwork = false).state

        assertEquals(ModelState.Downloading(0, OfflineModel.SIZE_BYTES, Waiting.WIFI), state)
    }

    @Test fun aPendingDownloadAllowedOnMobileDataIsJustQueued() {
        val state = decide(download = Download.Queued(null), allowMobileData = true, onUnmeteredNetwork = false).state

        assertEquals(ModelState.Downloading(0, OfflineModel.SIZE_BYTES, Waiting.OTHER), state)
    }

    @Test fun aQueuedDownloadHasNoFailure() {
        val decision = decide(download = Download.Queued(null))
        assertEquals(ModelState.Downloading(0, OfflineModel.SIZE_BYTES, Waiting.OTHER), decision.state)
        assertNull(decision.failure)
    }
}
