package com.voiceink.keyboard.offline

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.StatFs
import com.voiceink.keyboard.R
import java.io.File
import java.io.IOException

/**
 * The downloaded on-device model: DownloadManager fetches it (so it continues while the app is
 * closed, and holds it for Wi-Fi unless mobile data is allowed); [refresh] then checks it against
 * the pinned size and SHA-256 and moves it into the app's private storage. Only a verified file is
 * ever there, so [installedModel] is cheap enough for every dictation.
 */
internal class OfflineModelStore(context: Context) {
    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val downloads: DownloadManager? = app.getSystemService(DownloadManager::class.java)

    private val modelFile: File get() = File(File(app.noBackupFilesDir, MODEL_DIR), OfflineModel.FILE_NAME)

    /** The verified model, or null when it is not installed. */
    fun installedModel(): File? = modelFile.takeIf { it.isFile && it.length() == OfflineModel.SIZE_BYTES }

    val isReady: Boolean get() = installedModel() != null

    /** Whether there is room for the download and its private copy. */
    fun hasRoomForDownload(): Boolean = try {
        StatFs(app.noBackupFilesDir.path).availableBytes >= OfflineModel.FREE_SPACE_NEEDED
    } catch (_: IllegalArgumentException) {
        true
    }

    /** Starts (or restarts) the download under the network rule [allowMobileData] decides. */
    fun startDownload(allowMobileData: Boolean): Boolean = synchronized(LOCK) {
        val manager = downloads ?: return false
        forgetDownload(manager)
        if (!hasRoomForDownload()) {
            recordFailure(ModelFailure.NO_SPACE)
            return false
        }
        val policy = DownloadNetworkPolicy.of(allowMobileData)
        val request = DownloadManager.Request(Uri.parse(OfflineModel.URL))
            .setTitle(app.getString(R.string.offline_download_title))
            .setDescription(app.getString(R.string.offline_download_description))
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
            .setAllowedOverMetered(policy.allowedOverMetered)
            .setAllowedOverRoaming(policy.allowedOverRoaming)
            .setDestinationInExternalFilesDir(app, DOWNLOAD_DIR, OfflineModel.FILE_NAME + ".download")
        val id = try {
            manager.enqueue(request)
        } catch (_: RuntimeException) {
            // No external storage to download into, or the download service is off.
            recordFailure(ModelFailure.DOWNLOAD_FAILED)
            return false
        }
        prefs.edit()
            .putLong(KEY_DOWNLOAD_ID, id)
            .putBoolean(KEY_DOWNLOAD_ALLOWS_MOBILE, allowMobileData)
            .remove(KEY_LAST_FAILURE)
            .apply()
        true
    }

    /** Stops a download in progress and removes what it wrote. */
    fun cancelDownload() = synchronized(LOCK) {
        downloads?.let { forgetDownload(it) }
        prefs.edit().remove(KEY_LAST_FAILURE).apply()
    }

    /** Removes the model and any download. */
    fun delete() = synchronized(LOCK) {
        downloads?.let { forgetDownload(it) }
        modelFile.delete()
        File(modelFile.parentFile, modelFile.name + ".tmp").delete()
        prefs.edit().remove(KEY_LAST_FAILURE).apply()
    }

    /**
     * Reads the download's progress and acts on it: a finished download is verified and installed
     * (this reads the whole file, so call it off the main thread), a failed one is recorded.
     */
    fun refresh(): ModelState = synchronized(LOCK) {
        val manager = downloads
        val id = prefs.getLong(KEY_DOWNLOAD_ID, NO_DOWNLOAD).takeIf { it != NO_DOWNLOAD }
        val download = if (id != null && manager != null) query(manager, id) else null
        val decision = ModelLifecycle.decide(
            installed = isReady,
            download = download,
            lastFailure = lastFailure(),
            allowMobileData = prefs.getBoolean(KEY_DOWNLOAD_ALLOWS_MOBILE, false),
            onUnmeteredNetwork = onUnmeteredNetwork(),
        )
        when (decision.action) {
            ModelLifecycle.Action.NONE -> decision.state
            ModelLifecycle.Action.FORGET -> {
                manager?.let { forgetDownload(it) }
                decision.failure?.let(::recordFailure)
                decision.state
            }
            ModelLifecycle.Action.VERIFY -> verify(manager!!, id!!)
        }
    }

    private fun verify(manager: DownloadManager, id: Long): ModelState {
        val downloaded = File(app.getExternalFilesDir(DOWNLOAD_DIR), OfflineModel.FILE_NAME + ".download")
        val result = try {
            ModelVerification.install(downloaded, modelFile, OfflineModel.SIZE_BYTES, OfflineModel.SHA256)
        } catch (_: IOException) {
            ModelVerification.Result.WRONG_SIZE
        }
        val decision = ModelLifecycle.afterVerification(result)
        forgetDownload(manager)
        decision.failure?.let(::recordFailure)
        return decision.state
    }

    private fun onUnmeteredNetwork(): Boolean = try {
        val connectivity = app.getSystemService(ConnectivityManager::class.java)
        connectivity?.getNetworkCapabilities(connectivity.activeNetwork)
            ?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == true
    } catch (_: SecurityException) {
        true
    }

    private fun query(manager: DownloadManager, id: Long): ModelLifecycle.Download {
        val cursor = try {
            manager.query(DownloadManager.Query().setFilterById(id))
        } catch (_: RuntimeException) {
            null
        } ?: return ModelLifecycle.Download.Missing
        cursor.use {
            if (!it.moveToFirst()) return ModelLifecycle.Download.Missing
            val status = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            val reason = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
            val soFar = it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
            val total = it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
            return when (status) {
                DownloadManager.STATUS_PENDING -> ModelLifecycle.Download.Queued(null)
                DownloadManager.STATUS_RUNNING -> ModelLifecycle.Download.Running(soFar, total)
                DownloadManager.STATUS_PAUSED -> ModelLifecycle.Download.Paused(soFar, total, pause(reason))
                DownloadManager.STATUS_SUCCESSFUL -> ModelLifecycle.Download.Succeeded
                DownloadManager.STATUS_FAILED -> ModelLifecycle.Download.Failed(
                    noSpace = reason == DownloadManager.ERROR_INSUFFICIENT_SPACE,
                )
                else -> ModelLifecycle.Download.Missing
            }
        }
    }

    private fun pause(reason: Int): ModelLifecycle.Pause = when (reason) {
        DownloadManager.PAUSED_QUEUED_FOR_WIFI -> ModelLifecycle.Pause.QUEUED_FOR_WIFI
        DownloadManager.PAUSED_WAITING_FOR_NETWORK -> ModelLifecycle.Pause.WAITING_FOR_NETWORK
        else -> ModelLifecycle.Pause.OTHER
    }

    /** Removes the tracked download (DownloadManager deletes its file) and forgets its id. */
    private fun forgetDownload(manager: DownloadManager) {
        val id = prefs.getLong(KEY_DOWNLOAD_ID, NO_DOWNLOAD)
        if (id != NO_DOWNLOAD) {
            try {
                manager.remove(id)
            } catch (_: RuntimeException) {
            }
        }
        app.getExternalFilesDir(DOWNLOAD_DIR)?.listFiles()?.forEach { it.delete() }
        prefs.edit().remove(KEY_DOWNLOAD_ID).remove(KEY_DOWNLOAD_ALLOWS_MOBILE).apply()
    }

    private fun recordFailure(failure: ModelFailure) = prefs.edit().putString(KEY_LAST_FAILURE, failure.name).apply()

    private fun lastFailure(): ModelFailure? =
        prefs.getString(KEY_LAST_FAILURE, null)?.let { name -> ModelFailure.entries.firstOrNull { it.name == name } }

    fun registerListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) =
        prefs.registerOnSharedPreferenceChangeListener(listener)

    fun unregisterListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) =
        prefs.unregisterOnSharedPreferenceChangeListener(listener)

    private companion object {
        val LOCK = Any()
        const val PREFS = "offline_model"
        const val KEY_DOWNLOAD_ID = "download_id"
        const val KEY_DOWNLOAD_ALLOWS_MOBILE = "download_allows_mobile"
        const val KEY_LAST_FAILURE = "last_failure"
        const val NO_DOWNLOAD = -1L
        const val MODEL_DIR = "models"
        const val DOWNLOAD_DIR = "model-download"
    }
}

/** Verifies and installs the model as soon as DownloadManager finishes, even with the app closed. */
class ModelDownloadReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
        val pending = goAsync()
        val app = context.applicationContext
        Thread {
            try {
                OfflineModelStore(app).refresh()
            } finally {
                pending.finish()
            }
        }.start()
    }
}
