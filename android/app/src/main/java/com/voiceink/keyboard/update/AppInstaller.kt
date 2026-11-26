package com.voiceink.keyboard.update

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import java.io.File
import java.io.IOException

/**
 * Installs a downloaded, already verified APK of this app with the system package installer. The
 * user confirms the system prompt; Android checks that it is the same app signed with the same
 * key, so the update is an in-place upgrade that keeps the pairing and the settings.
 */
object AppInstaller {
    /**
     * Copies [apk] into an install session and commits it. [apk] is deleted in every case: the
     * session holds its own copy. Throws [IOException] when the session cannot be written.
     */
    fun install(context: Context, apk: File) {
        val installer = context.packageManager.packageInstaller
        var sessionId = -1
        try {
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                // The session fails if the APK is another app.
                setAppPackageName(context.packageName)
                setSize(apk.length())
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
                }
            }
            sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                apk.inputStream().use { input ->
                    session.openWrite("VoiceInkKeyboard.apk", 0, apk.length()).use { output ->
                        input.copyTo(output)
                        session.fsync(output)
                    }
                }
                val intent = Intent(context, InstallResultReceiver::class.java).setPackage(context.packageName)
                // Mutable: the installer adds the status and the confirmation intent as extras.
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                val pending = PendingIntent.getBroadcast(context, sessionId, intent, flags)
                session.commit(pending.intentSender)
            }
        } catch (e: IOException) {
            abandon(installer, sessionId)
            throw e
        } catch (e: SecurityException) {
            abandon(installer, sessionId)
            throw IOException(e.message, e)
        } finally {
            apk.delete()
        }
    }

    private fun abandon(installer: PackageInstaller, sessionId: Int) {
        if (sessionId < 0) return
        runCatching { installer.abandonSession(sessionId) }
    }
}

/** What became of the last install attempt, for the setup screen. */
class InstallResultStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("app_update", Context.MODE_PRIVATE)

    enum class Outcome { CANCELED, FAILED }

    fun save(outcome: Outcome, message: String?) {
        prefs.edit().putString(KEY_OUTCOME, outcome.name).putString(KEY_MESSAGE, message).apply()
    }

    /** Returns and clears the last outcome. */
    fun take(): Pair<Outcome, String?>? {
        val outcome = prefs.getString(KEY_OUTCOME, null)
            ?.let { name -> Outcome.entries.firstOrNull { it.name == name } } ?: return null
        val message = prefs.getString(KEY_MESSAGE, null)
        prefs.edit().remove(KEY_OUTCOME).remove(KEY_MESSAGE).apply()
        return outcome to message
    }

    fun registerListener(listener: android.content.SharedPreferences.OnSharedPreferenceChangeListener) =
        prefs.registerOnSharedPreferenceChangeListener(listener)

    fun unregisterListener(listener: android.content.SharedPreferences.OnSharedPreferenceChangeListener) =
        prefs.unregisterOnSharedPreferenceChangeListener(listener)

    private companion object {
        const val KEY_OUTCOME = "outcome"
        const val KEY_MESSAGE = "message"
    }
}

/** Receives the install session's status: shows the system prompt, then records the outcome. */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = confirmationIntent(intent) ?: run {
                    InstallResultStore(context).save(InstallResultStore.Outcome.FAILED, null)
                    return
                }
                context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            // An upgrade replaces this process; there is nothing to report.
            PackageInstaller.STATUS_SUCCESS -> Unit
            PackageInstaller.STATUS_FAILURE_ABORTED ->
                InstallResultStore(context).save(InstallResultStore.Outcome.CANCELED, null)
            else -> InstallResultStore(context).save(
                InstallResultStore.Outcome.FAILED,
                intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "status $status",
            )
        }
    }

    private fun confirmationIntent(intent: Intent): Intent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_INTENT)
        }
}
