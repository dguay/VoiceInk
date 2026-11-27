package com.voiceink.keyboard.setup

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.format.Formatter
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.voiceink.keyboard.R
import com.voiceink.keyboard.api.ApiError
import com.voiceink.keyboard.api.ApiResult
import com.voiceink.keyboard.api.Pairing
import com.voiceink.keyboard.api.PairingInput
import com.voiceink.keyboard.api.PairingParser
import com.voiceink.keyboard.api.VoiceInkClient
import com.voiceink.keyboard.bubble.BubbleSettings
import com.voiceink.keyboard.bubble.IdleCollapseTimeout
import com.voiceink.keyboard.bubble.MicBubbleService
import com.voiceink.keyboard.offline.ModelFailure
import com.voiceink.keyboard.offline.ModelState
import com.voiceink.keyboard.offline.OfflineModel
import com.voiceink.keyboard.offline.OfflineModelStore
import com.voiceink.keyboard.offline.OfflineSettings
import com.voiceink.keyboard.offline.Waiting
import com.voiceink.keyboard.store.PairingStore
import com.voiceink.keyboard.update.AppInstaller
import com.voiceink.keyboard.update.AppUpdateInfo
import com.voiceink.keyboard.update.AppUpdateOffer
import com.voiceink.keyboard.update.DownloadCheck
import com.voiceink.keyboard.update.InstallResultStore
import kotlinx.coroutines.Job
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException

/** Pairing with the Mac and the one-time keyboard setup. */
class MainActivity : Activity() {
    private val scope = MainScope()
    private val client = VoiceInkClient()
    private lateinit var store: PairingStore
    private lateinit var bubbleSettings: BubbleSettings

    private lateinit var pairedSummary: TextView
    private lateinit var pairingResult: TextView
    private lateinit var addressField: EditText
    private lateinit var portField: EditText
    private lateinit var tokenField: EditText
    private lateinit var connectButton: Button
    private lateinit var scanButton: Button
    private lateinit var unpairButton: Button
    private lateinit var micStatus: TextView
    private lateinit var micButton: Button
    private lateinit var keyboardStatus: TextView
    private lateinit var bubbleStatus: TextView
    private lateinit var bubbleButton: Button
    private lateinit var excludedSummary: TextView
    private lateinit var idleCollapseSpinner: Spinner
    private lateinit var resetBubbleButton: Button
    private val idleCollapseOptions = IdleCollapseTimeout.entries
    // The bubble can be dragged over this screen; show Reset as soon as it is.
    private val bubbleSettingsChanged = SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> refresh() }

    private lateinit var installResults: InstallResultStore
    private lateinit var updateSection: View
    private lateinit var updateVersion: TextView
    private lateinit var updateDetail: TextView
    private lateinit var updateButton: Button
    /** The newer version the Mac offers, if any. */
    private var offeredUpdate: AppUpdateInfo? = null
    private var macCheck: Job? = null
    private var updating = false
    /** The user went to the install permission setting; continue the update when they come back. */
    private var installAfterPermission = false
    private val installResultChanged = SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> showInstallResult() }

    private lateinit var offlineModel: OfflineModelStore
    private lateinit var offlineSettings: OfflineSettings
    private lateinit var offlineStatus: TextView
    private lateinit var offlineProgress: ProgressBar
    private lateinit var offlineAllowMobile: CheckBox
    private lateinit var offlineDownload: Button
    private lateinit var offlineDelete: Button
    private lateinit var offlineModeSwitch: Switch
    private lateinit var offlineFallbackSwitch: Switch
    private var offlineState: ModelState = ModelState.Absent
    private var offlineWatch: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        applySystemBarInsets(findViewById(R.id.scroll))
        store = PairingStore(this)
        bubbleSettings = BubbleSettings(this)

        pairedSummary = findViewById(R.id.paired_summary)
        pairingResult = findViewById(R.id.pairing_result)
        addressField = findViewById(R.id.address)
        portField = findViewById(R.id.port)
        tokenField = findViewById(R.id.token)
        connectButton = findViewById(R.id.connect)
        scanButton = findViewById(R.id.scan)
        unpairButton = findViewById(R.id.unpair)
        micStatus = findViewById(R.id.mic_status)
        micButton = findViewById(R.id.mic_permission)
        keyboardStatus = findViewById(R.id.keyboard_status)
        bubbleStatus = findViewById(R.id.bubble_status)
        bubbleButton = findViewById(R.id.open_accessibility_settings)
        excludedSummary = findViewById(R.id.excluded_summary)
        idleCollapseSpinner = findViewById(R.id.idle_collapse_spinner)
        resetBubbleButton = findViewById(R.id.reset_bubble_position)
        installResults = InstallResultStore(this)
        updateSection = findViewById(R.id.update_section)
        updateVersion = findViewById(R.id.update_version)
        updateDetail = findViewById(R.id.update_detail)
        updateButton = findViewById(R.id.update_button)
        updateButton.setOnClickListener { onUpdateTapped() }
        installAfterPermission = savedInstanceState?.getBoolean(STATE_INSTALL_AFTER_PERMISSION) ?: false
        // A download left over from an interrupted attempt is never installed.
        if (savedInstanceState == null) updateDirectory().deleteRecursively()

        connectButton.setOnClickListener {
            pair(PairingParser.parseManual(addressField.text.toString(), portField.text.toString(), tokenField.text.toString()))
        }
        scanButton.setOnClickListener { scan() }
        unpairButton.setOnClickListener {
            store.clear()
            pairingResult.text = ""
            showOffer(null)
            refresh()
        }
        micButton.setOnClickListener { requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_MIC) }
        findViewById<Button>(R.id.open_keyboard_settings).setOnClickListener {
            startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        }
        bubbleButton.setOnClickListener { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
        findViewById<Button>(R.id.choose_excluded_apps).setOnClickListener {
            startActivity(Intent(this, BubbleExclusionsActivity::class.java))
        }
        setupIdleCollapseSpinner()
        resetBubbleButton.setOnClickListener {
            bubbleSettings.resetPosition()
            refresh()
        }
        findViewById<Button>(R.id.show_picker).setOnClickListener {
            getSystemService(InputMethodManager::class.java).showInputMethodPicker()
        }

        setupOfflineModel()

        handleReason(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleReason(intent)
    }

    override fun onResume() {
        super.onResume()
        bubbleSettings.registerListener(bubbleSettingsChanged)
        installResults.registerListener(installResultChanged)
        refresh()
        showInstallResult()
        watchOfflineModel()
        if (!continueAfterPermission()) checkMac()
    }

    override fun onPause() {
        offlineWatch?.cancel()
        bubbleSettings.unregisterListener(bubbleSettingsChanged)
        installResults.unregisterListener(installResultChanged)
        super.onPause()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(STATE_INSTALL_AFTER_PERMISSION, installAfterPermission)
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_MIC) refresh()
    }

    private fun handleReason(intent: Intent?) {
        when (intent?.getStringExtra(EXTRA_REASON)) {
            REASON_REJECTED -> pairingResult.text = getString(R.string.pair_rejected_from_keyboard)
            REASON_MICROPHONE -> if (!hasMicrophone()) {
                requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_MIC)
            }
            REASON_OFFLINE_MODEL -> {
                val scroll = findViewById<ScrollView>(R.id.scroll)
                val section = findViewById<View>(R.id.offline_section)
                scroll.post { scroll.smoothScrollTo(0, section.top) }
            }
        }
    }

    private fun refresh() {
        val pairing = store.load()
        if (pairing != null) {
            val address = getString(R.string.address_format, pairing.hosts.joinToString(), pairing.port)
            val model = store.model
            pairedSummary.text = if (model != null) {
                getString(R.string.paired_with_model, pairing.name, address, model)
            } else {
                getString(R.string.paired_with, pairing.name, address)
            }
            unpairButton.visibility = View.VISIBLE
        } else {
            pairedSummary.text = getString(R.string.not_paired)
            unpairButton.visibility = View.GONE
        }

        val mic = hasMicrophone()
        micStatus.text = getString(if (mic) R.string.mic_granted else R.string.mic_rationale)
        micButton.visibility = if (mic) View.GONE else View.VISIBLE

        keyboardStatus.text = getString(
            when {
                !isKeyboardEnabled() -> R.string.keyboard_not_enabled
                else -> R.string.keyboard_enabled
            },
        )

        val bubble = isBubbleEnabled()
        bubbleStatus.text = getString(if (bubble) R.string.bubble_enabled else R.string.bubble_not_enabled)
        bubbleButton.visibility = if (bubble) View.GONE else View.VISIBLE
        val excluded = bubbleSettings.excludedApps.size
        excludedSummary.text = if (excluded == 0) {
            getString(R.string.no_excluded_apps)
        } else {
            resources.getQuantityString(R.plurals.excluded_apps_count, excluded, excluded)
        }
        val selectedCollapse = idleCollapseOptions.indexOf(bubbleSettings.idleCollapse).coerceAtLeast(0)
        if (idleCollapseSpinner.selectedItemPosition != selectedCollapse) {
            idleCollapseSpinner.setSelection(selectedCollapse, false)
        }
        resetBubbleButton.visibility = if (bubbleSettings.hasCustomPosition) View.VISIBLE else View.GONE
    }

    private fun setupIdleCollapseSpinner() {
        val labels = idleCollapseOptions.map { getString(idleCollapseLabel(it)) }
        idleCollapseSpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_item, labels).apply {
            setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        }
        val initial = idleCollapseOptions.indexOf(bubbleSettings.idleCollapse).coerceAtLeast(0)
        idleCollapseSpinner.setSelection(initial, false)
        idleCollapseSpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                val chosen = idleCollapseOptions.getOrNull(position) ?: return
                if (bubbleSettings.idleCollapse != chosen) {
                    bubbleSettings.idleCollapse = chosen
                }
            }

            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }
    }

    private fun idleCollapseLabel(timeout: IdleCollapseTimeout): Int = when (timeout) {
        IdleCollapseTimeout.OFF -> R.string.idle_collapse_off
        IdleCollapseTimeout.SECONDS_5 -> R.string.idle_collapse_5s
        IdleCollapseTimeout.SECONDS_10 -> R.string.idle_collapse_10s
        IdleCollapseTimeout.SECONDS_30 -> R.string.idle_collapse_30s
    }

    // MARK: On-device offline model

    private fun setupOfflineModel() {
        offlineModel = OfflineModelStore(this)
        offlineSettings = OfflineSettings(this)
        offlineStatus = findViewById(R.id.offline_status)
        offlineProgress = findViewById(R.id.offline_progress)
        offlineAllowMobile = findViewById(R.id.offline_allow_mobile)
        offlineDownload = findViewById(R.id.offline_download)
        offlineDelete = findViewById(R.id.offline_delete)
        offlineModeSwitch = findViewById(R.id.offline_mode)
        offlineFallbackSwitch = findViewById(R.id.offline_auto_fallback)

        offlineAllowMobile.isChecked = offlineSettings.allowMobileData
        offlineAllowMobile.setOnCheckedChangeListener { _, checked ->
            if (offlineSettings.allowMobileData == checked) return@setOnCheckedChangeListener
            offlineSettings.allowMobileData = checked
            // DownloadManager fixes the network rule when the download starts: restart under the new one.
            if (offlineState is ModelState.Downloading) startOfflineDownload()
        }
        offlineDownload.setOnClickListener {
            when (offlineState) {
                is ModelState.Downloading -> {
                    offlineModel.cancelDownload()
                    watchOfflineModel()
                }
                ModelState.Absent, is ModelState.Failed -> startOfflineDownload()
                ModelState.Verifying, ModelState.Ready -> Unit
            }
        }
        offlineDelete.setOnClickListener {
            offlineModel.delete()
            // Without the model, Offline mode would only block dictation.
            offlineSettings.offlineMode = false
            watchOfflineModel()
        }
        offlineModeSwitch.setOnCheckedChangeListener { _, checked ->
            if (offlineSettings.offlineMode != checked) offlineSettings.offlineMode = checked
        }
        offlineFallbackSwitch.setOnCheckedChangeListener { _, checked ->
            if (offlineSettings.autoFallback != checked) offlineSettings.autoFallback = checked
        }
        showOfflineState(offlineState)
    }

    private fun startOfflineDownload() {
        offlineModel.startDownload(offlineSettings.allowMobileData)
        watchOfflineModel()
    }

    /** Shows the model's state, and follows it while a download or its check is in progress. */
    private fun watchOfflineModel() {
        offlineWatch?.cancel()
        offlineWatch = scope.launch {
            while (true) {
                val state = withContext(Dispatchers.IO) { offlineModel.refresh() }
                showOfflineState(state)
                if (state !is ModelState.Downloading && state != ModelState.Verifying) break
                delay(OFFLINE_POLL_MS)
            }
        }
    }

    private fun showOfflineState(state: ModelState) {
        offlineState = state
        val size = { bytes: Long -> Formatter.formatShortFileSize(this, bytes) }
        offlineStatus.text = when (state) {
            ModelState.Absent -> getString(R.string.offline_absent)
            is ModelState.Downloading -> when (state.waiting) {
                null -> getString(R.string.offline_downloading, size(state.downloaded), size(state.total))
                Waiting.WIFI -> getString(R.string.offline_waiting_wifi, size(state.downloaded), size(state.total))
                Waiting.NETWORK -> getString(R.string.offline_waiting_network, size(state.downloaded), size(state.total))
                Waiting.OTHER -> getString(R.string.offline_waiting_other, size(state.downloaded), size(state.total))
            }
            ModelState.Verifying -> getString(R.string.offline_verifying)
            ModelState.Ready -> getString(R.string.offline_ready, size(OfflineModel.SIZE_BYTES))
            is ModelState.Failed -> when (state.failure) {
                ModelFailure.DOWNLOAD_FAILED -> getString(R.string.offline_failed_download)
                ModelFailure.CORRUPTED -> getString(R.string.offline_failed_corrupted)
                ModelFailure.NO_SPACE -> getString(R.string.offline_failed_no_space, size(OfflineModel.FREE_SPACE_NEEDED))
            }
        }

        when (state) {
            is ModelState.Downloading -> {
                offlineProgress.visibility = View.VISIBLE
                offlineProgress.isIndeterminate = false
                offlineProgress.progress = if (state.total > 0) (state.downloaded * 1000 / state.total).toInt() else 0
            }
            ModelState.Verifying -> {
                offlineProgress.visibility = View.VISIBLE
                offlineProgress.isIndeterminate = true
            }
            else -> offlineProgress.visibility = View.GONE
        }

        val ready = state == ModelState.Ready
        offlineDownload.visibility = if (ready) View.GONE else View.VISIBLE
        offlineDownload.isEnabled = state != ModelState.Verifying
        offlineDownload.setText(if (state is ModelState.Downloading || state == ModelState.Verifying) R.string.offline_cancel else R.string.offline_download)
        offlineDelete.visibility = if (ready) View.VISIBLE else View.GONE
        offlineAllowMobile.visibility = if (ready) View.GONE else View.VISIBLE
        offlineAllowMobile.isEnabled = state != ModelState.Verifying
        offlineModeSwitch.isEnabled = ready
        offlineFallbackSwitch.isEnabled = ready
        offlineModeSwitch.isChecked = offlineSettings.offlineMode
        offlineFallbackSwitch.isChecked = offlineSettings.autoFallback
    }

    // MARK: Update from the paired Mac

    /**
     * Checks the paired Mac's status, then whether it offers a newer version of this app. Neither
     * result interrupts the setup screen: failures just offer nothing.
     */
    private fun checkMac() {
        val pairing = store.load() ?: return showOffer(null)
        if (updating || macCheck?.isActive == true) return
        macCheck = scope.launch {
            val status = withContext(Dispatchers.IO) { client.status(pairing, store.lastHost) }
            val host = when (status) {
                is ApiResult.Success -> status.host
                is ApiResult.Failure -> when (status.error) {
                    // Nothing to ask a Mac that is away or no longer accepts the token.
                    ApiError.Unreachable, ApiError.Unauthorized -> return@launch
                    else -> store.lastHost
                }
            }
            checkForUpdate(pairing, host)
        }
    }

    private fun checkForUpdate(pairing: Pairing, host: String?) {
        scope.launch {
            val response = withContext(Dispatchers.IO) { client.appUpdate(pairing, host) }
            if (updating) return@launch
            showOffer(AppUpdateOffer.from(installedVersionCode(), response))
            continueAfterPermission()
        }
    }

    private fun showOffer(update: AppUpdateInfo?) {
        if (update != offeredUpdate) updateDetail.visibility = View.GONE
        offeredUpdate = update
        if (update == null) {
            updateSection.visibility = View.GONE
            return
        }
        val macName = store.load()?.name ?: getString(R.string.your_mac)
        updateVersion.text = getString(R.string.update_available_version, update.versionName, macName, installedVersionName())
        updateSection.visibility = View.VISIBLE
        showUpdateAction()
    }

    /** Download and install, or first the permission to install, with why it is needed. */
    private fun showUpdateAction() {
        val allowed = packageManager.canRequestPackageInstalls()
        updateButton.text = getString(if (allowed) R.string.update_install else R.string.update_allow_installs)
        updateButton.isEnabled = !updating
        if (!allowed && !updating) showUpdateDetail(getString(R.string.update_permission_needed))
    }

    private fun showUpdateDetail(text: String) {
        updateDetail.text = text
        updateDetail.visibility = View.VISIBLE
    }

    /** Starts the update the user was granting the install permission for. */
    private fun continueAfterPermission(): Boolean {
        if (!installAfterPermission || offeredUpdate == null || updating) return false
        if (!packageManager.canRequestPackageInstalls()) return false
        installAfterPermission = false
        startUpdate()
        return true
    }

    private fun onUpdateTapped() {
        if (offeredUpdate == null || updating) return
        if (!packageManager.canRequestPackageInstalls()) {
            installAfterPermission = true
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            return
        }
        startUpdate()
    }

    private enum class UpdateOutcome { CONFIRMING, CORRUPTED, GONE, DOWNLOAD_FAILED, INSTALL_FAILED }

    /** Downloads the offered APK, checks it against the advertised size and hash, then installs it. */
    private fun startUpdate() {
        val update = offeredUpdate ?: return
        val pairing = store.load() ?: return showOffer(null)
        updating = true
        showUpdateAction()
        showUpdateDetail(getString(R.string.update_downloading, pairing.name))
        scope.launch {
            val outcome = withContext(Dispatchers.IO) { downloadAndInstall(pairing, update) }
            updating = false
            showUpdateAction()
            showUpdateDetail(
                when (outcome) {
                    UpdateOutcome.CONFIRMING -> getString(R.string.update_confirm)
                    UpdateOutcome.CORRUPTED -> getString(R.string.update_corrupted)
                    UpdateOutcome.GONE -> getString(R.string.update_gone)
                    UpdateOutcome.DOWNLOAD_FAILED -> getString(R.string.update_download_failed)
                    UpdateOutcome.INSTALL_FAILED -> getString(R.string.update_failed_unknown)
                },
            )
            if (outcome == UpdateOutcome.GONE) checkMac()
        }
    }

    private fun downloadAndInstall(pairing: Pairing, update: AppUpdateInfo): UpdateOutcome {
        val directory = updateDirectory()
        val apk = File(directory, "VoiceInkKeyboard.apk")
        try {
            directory.mkdirs()
            apk.delete()
            when (val download = client.downloadAppUpdate(pairing, apk, update.size, store.lastHost)) {
                is ApiResult.Failure -> {
                    val error = download.error
                    return if (error is ApiError.Server && error.httpStatus == 404) UpdateOutcome.GONE else UpdateOutcome.DOWNLOAD_FAILED
                }
                is ApiResult.Success -> Unit
            }
            if (DownloadCheck.verify(apk, update) != DownloadCheck.Result.MATCHES) return UpdateOutcome.CORRUPTED
            AppInstaller.install(this, apk)
            return UpdateOutcome.CONFIRMING
        } catch (_: IOException) {
            return if (apk.exists()) UpdateOutcome.DOWNLOAD_FAILED else UpdateOutcome.INSTALL_FAILED
        } finally {
            // Installed or not, the download never stays on the phone.
            apk.delete()
        }
    }

    /** Shows what became of an install the user confirmed, canceled or that failed. */
    private fun showInstallResult() {
        val (outcome, message) = installResults.take() ?: return
        if (offeredUpdate == null) return
        showUpdateDetail(
            when (outcome) {
                InstallResultStore.Outcome.CANCELED -> getString(R.string.update_canceled)
                InstallResultStore.Outcome.FAILED ->
                    message?.let { getString(R.string.update_failed, it) } ?: getString(R.string.update_failed_unknown)
            },
        )
    }

    /** App-private storage for the download; nothing else can read it. */
    private fun updateDirectory(): File = File(noBackupFilesDir, "updates")

    private fun installedVersionCode(): Long = installedPackage().longVersionCode

    private fun installedVersionName(): String = installedPackage().versionName.orEmpty()

    private fun installedPackage(): PackageInfo =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(packageName, 0)
        }

    private fun scan() {
        val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
        GmsBarcodeScanning.getClient(this, options).startScan()
            .addOnSuccessListener { barcode -> pair(PairingParser.parseQrCode(barcode.rawValue.orEmpty())) }
            .addOnFailureListener { pairingResult.text = getString(R.string.scan_unavailable) }
    }

    private fun pair(input: PairingInput) {
        val pairing = when (input) {
            is PairingInput.Invalid -> {
                pairingResult.text = getString(invalidMessage(input.reason))
                return
            }
            is PairingInput.Valid -> input.pairing
        }
        setBusy(true)
        pairingResult.text = getString(R.string.pair_checking)
        scope.launch {
            val result = withContext(Dispatchers.IO) { client.status(pairing) }
            setBusy(false)
            pairingResult.text = when (result) {
                is ApiResult.Success -> {
                    store.save(pairing, result.host, result.value.model)
                    tokenField.text.clear()
                    checkForUpdate(pairing, result.host)
                    getString(R.string.pair_success, pairing.name, result.value.model)
                }
                is ApiResult.Failure -> pairingFailure(pairing, result.error)
            }
            refresh()
        }
    }

    private fun pairingFailure(pairing: Pairing, error: ApiError): String = when (error) {
        ApiError.Unreachable -> getString(R.string.pair_unreachable, pairing.hosts.joinToString(), pairing.port)
        ApiError.Unauthorized -> getString(R.string.pair_wrong_token)
        is ApiError.NoModelSelected -> {
            // The token is valid; save the pairing and tell the user what the Mac still needs.
            store.save(pairing, pairing.hosts.first(), null)
            getString(R.string.pair_no_model, pairing.name)
        }
        is ApiError.TranscriptionFailed, is ApiError.Server, is ApiError.InvalidResponse -> getString(R.string.pair_unexpected)
    }

    private fun invalidMessage(reason: PairingInput.Reason): Int = when (reason) {
        PairingInput.Reason.NOT_A_VOICEINK_CODE -> R.string.invalid_not_voiceink
        PairingInput.Reason.UNSUPPORTED_VERSION -> R.string.invalid_version
        PairingInput.Reason.MISSING_ADDRESS -> R.string.invalid_missing_address
        PairingInput.Reason.BAD_ADDRESS -> R.string.invalid_bad_address
        PairingInput.Reason.BAD_PORT -> R.string.invalid_bad_port
        PairingInput.Reason.MISSING_TOKEN -> R.string.invalid_missing_token
    }

    private fun setBusy(busy: Boolean) {
        connectButton.isEnabled = !busy
        scanButton.isEnabled = !busy
    }

    private fun hasMicrophone(): Boolean =
        checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun isKeyboardEnabled(): Boolean =
        getSystemService(InputMethodManager::class.java).enabledInputMethodList.any { it.packageName == packageName }

    private fun isBubbleEnabled(): Boolean = AccessibilitySetting.isEnabled(
        Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES),
        packageName,
        MicBubbleService::class.java.name,
    )

    companion object {
        const val EXTRA_REASON = "reason"
        const val REASON_PAIR = "pair"
        const val REASON_REJECTED = "rejected"
        const val REASON_MICROPHONE = "microphone"
        const val REASON_OFFLINE_MODEL = "offline_model"
        private const val OFFLINE_POLL_MS = 500L
        private const val REQUEST_MIC = 1
        private const val STATE_INSTALL_AFTER_PERMISSION = "install_after_permission"
    }
}
