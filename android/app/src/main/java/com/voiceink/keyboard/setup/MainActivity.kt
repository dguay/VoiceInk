package com.voiceink.keyboard.setup

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
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
import com.voiceink.keyboard.store.PairingStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Pairing with the Mac and the one-time keyboard setup. */
class MainActivity : Activity() {
    private val scope = MainScope()
    private val client = VoiceInkClient()
    private lateinit var store: PairingStore

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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        applySystemBarInsets(findViewById(R.id.scroll))
        store = PairingStore(this)

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

        connectButton.setOnClickListener {
            pair(PairingParser.parseManual(addressField.text.toString(), portField.text.toString(), tokenField.text.toString()))
        }
        scanButton.setOnClickListener { scan() }
        unpairButton.setOnClickListener {
            store.clear()
            pairingResult.text = ""
            refresh()
        }
        micButton.setOnClickListener { requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_MIC) }
        findViewById<Button>(R.id.open_keyboard_settings).setOnClickListener {
            startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        }
        findViewById<Button>(R.id.show_picker).setOnClickListener {
            getSystemService(InputMethodManager::class.java).showInputMethodPicker()
        }

        handleReason(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleReason(intent)
    }

    override fun onResume() {
        super.onResume()
        refresh()
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

    companion object {
        const val EXTRA_REASON = "reason"
        const val REASON_PAIR = "pair"
        const val REASON_REJECTED = "rejected"
        const val REASON_MICROPHONE = "microphone"
        private const val REQUEST_MIC = 1
    }
}
