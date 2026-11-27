package com.voiceink.keyboard.offline

/** What the setup screen shows for the on-device model. */
internal sealed interface ModelState {
    data object Absent : ModelState

    /** [waiting] says why no bytes are flowing right now, or is null while downloading. */
    data class Downloading(val downloaded: Long, val total: Long, val waiting: Waiting?) : ModelState
    data object Verifying : ModelState
    data object Ready : ModelState
    data class Failed(val failure: ModelFailure) : ModelState
}

internal enum class Waiting { WIFI, NETWORK, OTHER }

internal enum class ModelFailure {
    /** The download stopped for good (server or network error). */
    DOWNLOAD_FAILED,

    /** The file did not match the pinned size and SHA-256; it was deleted. */
    CORRUPTED,

    /** Not enough free storage for the download. */
    NO_SPACE,
}

/**
 * Pure rules for the model's lifecycle: Absent → Downloading → Verifying → Ready, with Failed
 * after a broken download or a file that does not match, so they are unit-tested apart from
 * DownloadManager and the file system.
 */
internal object ModelLifecycle {
    /** DownloadManager's view of the download, in this app's terms. */
    sealed interface Download {
        /** DownloadManager no longer knows it (removed from the Downloads app, or data cleared). */
        data object Missing : Download
        data class Queued(val pause: Pause?) : Download
        data class Running(val downloaded: Long, val total: Long) : Download
        data class Paused(val downloaded: Long, val total: Long, val pause: Pause) : Download
        data object Succeeded : Download
        data class Failed(val noSpace: Boolean) : Download
    }

    enum class Pause { QUEUED_FOR_WIFI, WAITING_FOR_NETWORK, OTHER }

    enum class Action {
        NONE,

        /** Check the finished download and, if it matches, install it. */
        VERIFY,

        /** Drop the download id (and remove what DownloadManager kept), recording [Decision.failure]. */
        FORGET,
    }

    data class Decision(val state: ModelState, val action: Action = Action.NONE, val failure: ModelFailure? = null)

    /**
     * The state to show and what to do about it. [installed] means the verified model is in place;
     * [download] is null when no download is tracked; [lastFailure] is the outcome of the last one.
     * [onUnmeteredNetwork]: the phone is on Wi-Fi (or another unmetered network) right now.
     */
    fun decide(
        installed: Boolean,
        download: Download?,
        lastFailure: ModelFailure?,
        allowMobileData: Boolean,
        onUnmeteredNetwork: Boolean = true,
    ): Decision {
        val wifiMissing = !allowMobileData && !onUnmeteredNetwork
        if (installed) return Decision(ModelState.Ready, if (download != null) Action.FORGET else Action.NONE)
        return when (download) {
            null -> Decision(lastFailure?.let { ModelState.Failed(it) } ?: ModelState.Absent)
            Download.Missing -> Decision(ModelState.Absent, Action.FORGET)
            // Recent Android versions keep a download that waits for Wi-Fi pending, without a reason.
            is Download.Queued -> Decision(
                ModelState.Downloading(
                    0,
                    OfflineModel.SIZE_BYTES,
                    download.pause?.let { waiting(it, allowMobileData) } ?: if (wifiMissing) Waiting.WIFI else Waiting.OTHER,
                ),
            )
            is Download.Running -> Decision(ModelState.Downloading(download.downloaded, total(download.total), null))
            is Download.Paused -> {
                val waiting = waiting(download.pause, allowMobileData).let { if (it == Waiting.OTHER && wifiMissing) Waiting.WIFI else it }
                Decision(ModelState.Downloading(download.downloaded, total(download.total), waiting))
            }
            Download.Succeeded -> Decision(ModelState.Verifying, Action.VERIFY)
            is Download.Failed -> {
                val failure = if (download.noSpace) ModelFailure.NO_SPACE else ModelFailure.DOWNLOAD_FAILED
                Decision(ModelState.Failed(failure), Action.FORGET, failure)
            }
        }
    }

    /** The outcome of [Action.VERIFY]: installed, or deleted as corrupted. */
    fun afterVerification(result: ModelVerification.Result): Decision = when (result) {
        ModelVerification.Result.MATCHES -> Decision(ModelState.Ready, Action.FORGET)
        ModelVerification.Result.WRONG_SIZE, ModelVerification.Result.WRONG_HASH ->
            Decision(ModelState.Failed(ModelFailure.CORRUPTED), Action.FORGET, ModelFailure.CORRUPTED)
    }

    /**
     * Without mobile data allowed, any wait for a network is a wait for Wi-Fi: DownloadManager
     * holds the download until an unmetered network is up.
     */
    private fun waiting(pause: Pause, allowMobileData: Boolean): Waiting = when (pause) {
        Pause.QUEUED_FOR_WIFI -> Waiting.WIFI
        Pause.WAITING_FOR_NETWORK -> if (allowMobileData) Waiting.NETWORK else Waiting.WIFI
        Pause.OTHER -> Waiting.OTHER
    }

    private fun total(reported: Long) = if (reported > 0) reported else OfflineModel.SIZE_BYTES
}

/** DownloadManager's network rules for the model: Wi-Fi only unless the user allowed mobile data. */
internal data class DownloadNetworkPolicy(val allowedOverMetered: Boolean, val allowedOverRoaming: Boolean) {
    companion object {
        fun of(allowMobileData: Boolean) = DownloadNetworkPolicy(allowedOverMetered = allowMobileData, allowedOverRoaming = allowMobileData)
    }
}
