package com.voiceink.keyboard.ime

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.ImageButton
import android.widget.ProgressBar
import android.widget.TextView
import com.voiceink.keyboard.R
import com.voiceink.keyboard.api.ApiError
import com.voiceink.keyboard.api.ApiResult
import com.voiceink.keyboard.api.Pairing
import com.voiceink.keyboard.api.Transcription
import com.voiceink.keyboard.api.VoiceInkClient
import com.voiceink.keyboard.setup.MainActivity
import com.voiceink.keyboard.store.PairingStore
import com.voiceink.keyboard.store.PendingRecording
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * A voice-only keyboard: one mic button and a status line. A finished recording is sent to the
 * paired Mac, the returned text is inserted at the cursor and the previous keyboard comes back.
 */
class VoiceKeyboardService : InputMethodService() {
    private val scope: CoroutineScope = MainScope()
    private val delivery = TextDelivery()
    private val client = VoiceInkClient()
    private lateinit var pairingStore: PairingStore
    private lateinit var pending: PendingRecording
    private lateinit var recorder: AudioRecorder

    private var state: KeyboardState = KeyboardState.Idle

    private var statusView: TextView? = null
    private var micButton: ImageButton? = null
    private var progress: ProgressBar? = null
    private var actionButton: Button? = null
    private var discardButton: Button? = null

    override fun onCreate() {
        super.onCreate()
        pairingStore = PairingStore(this)
        pending = PendingRecording(this)
        recorder = AudioRecorder(this)
    }

    override fun onDestroy() {
        recorder.stop()?.let { pending.keep(it) }
        scope.cancel()
        super.onDestroy()
    }

    override fun onEvaluateFullscreenMode(): Boolean = false

    // An input view has no parent until the framework attaches it.
    @android.annotation.SuppressLint("InflateParams")
    override fun onCreateInputView(): View {
        val root = layoutInflater.inflate(R.layout.keyboard, null)
        statusView = root.findViewById(R.id.status)
        micButton = root.findViewById<ImageButton>(R.id.mic).apply { setOnClickListener { onMicTapped() } }
        progress = root.findViewById(R.id.progress)
        actionButton = root.findViewById<Button>(R.id.action).apply { setOnClickListener { onActionTapped() } }
        discardButton = root.findViewById<Button>(R.id.discard).apply {
            setOnClickListener {
                pending.discard()
                setState(KeyboardState.Idle)
            }
        }
        root.findViewById<ImageButton>(R.id.switch_back).setOnClickListener { switchBack() }
        render()
        return root
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        delivery.startSession(sameField = restarting)
        val opening = KeyboardOpening.decide(
            current = state,
            restarting = restarting,
            textField = info != null && info.inputType != InputType.TYPE_NULL,
            paired = pairingStore.load() != null,
            hasMicrophone = hasMicrophone(),
            hasKeptRecording = pending.exists(),
        )
        setState(opening.state)
        if (opening.startRecording) startRecording()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        delivery.endSession()
        if (recorder.isRecording) {
            // Never send audio into a field the user has left; keep it for a retry instead.
            val file = recorder.stop()
            if (file != null && pending.keep(file)) setState(KeyboardState.Kept(null)) else setState(KeyboardState.Idle)
        }
        super.onFinishInputView(finishingInput)
    }

    override fun onFinishInput() {
        // The editor connection ended (field or app changed), even if the view stays up.
        delivery.endSession()
        super.onFinishInput()
    }

    private fun onMicTapped() {
        when (state) {
            KeyboardState.Recording -> finishRecording()
            KeyboardState.Sending -> Unit
            is KeyboardState.Kept -> send()
            KeyboardState.NotPaired -> openApp(MainActivity.REASON_PAIR)
            KeyboardState.NeedsMicrophone -> openApp(MainActivity.REASON_MICROPHONE)
            KeyboardState.Idle, KeyboardState.NoSpeech, KeyboardState.RecorderFailed -> startRecording()
        }
    }

    private fun onActionTapped() {
        when (val s = state) {
            KeyboardState.NotPaired -> openApp(MainActivity.REASON_PAIR)
            KeyboardState.NeedsMicrophone -> openApp(MainActivity.REASON_MICROPHONE)
            is KeyboardState.Kept -> if (s.error == ApiError.Unauthorized) openApp(MainActivity.REASON_REJECTED) else send()
            else -> Unit
        }
    }

    private fun startRecording() {
        if (pairingStore.load() == null) return setState(KeyboardState.NotPaired)
        if (!hasMicrophone()) return setState(KeyboardState.NeedsMicrophone)
        try {
            recorder.start(pending.newScratchFile()) { if (state == KeyboardState.Recording) finishRecording() }
            setState(KeyboardState.Recording)
        } catch (_: Exception) {
            setState(KeyboardState.RecorderFailed)
        }
    }

    private fun finishRecording() {
        val file = recorder.stop()
        if (file == null || !pending.keep(file)) return setState(KeyboardState.NoSpeech)
        send()
    }

    private fun send() {
        val pairing = pairingStore.load() ?: return setState(KeyboardState.NotPaired)
        if (!pending.exists()) return setState(KeyboardState.Idle)
        setState(KeyboardState.Sending)
        val ticket = delivery.ticket()
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                client.transcribe(pairing, pending.file, "audio/mp4", pairingStore.lastHost)
            }
            onTranscribed(pairing, ticket, result)
        }
    }

    private fun onTranscribed(pairing: Pairing, ticket: TextDelivery.Ticket, result: ApiResult<Transcription>) {
        when (result) {
            is ApiResult.Failure -> setState(KeyboardState.Kept(result.error))
            is ApiResult.Success -> {
                pairingStore.lastHost = result.host
                val outcome = delivery.deliver(ticket, result.value.text.trim(), ::commit, pending::discard)
                when (outcome) {
                    TextDelivery.Outcome.INSERTED -> {
                        setState(KeyboardState.Idle)
                        statusView?.text = getString(R.string.status_inserted, pairing.name)
                        switchBack()
                    }
                    TextDelivery.Outcome.EMPTY -> setState(KeyboardState.NoSpeech)
                    TextDelivery.Outcome.FIELD_CHANGED -> setState(KeyboardState.Kept(null, KeptReason.FIELD_CHANGED))
                    TextDelivery.Outcome.REJECTED -> setState(KeyboardState.Kept(null, KeptReason.REJECTED))
                }
            }
        }
    }

    /** Types [text] at the cursor, separated from a preceding word by a space. */
    private fun commit(text: String): Boolean {
        val connection = currentInputConnection ?: return false
        val before = connection.getTextBeforeCursor(1, 0)
        val separator = if (!before.isNullOrEmpty() && !before.last().isWhitespace()) " " else ""
        return connection.commitText(separator + text, 1)
    }

    private fun switchBack() {
        if (recorder.isRecording) {
            recorder.stop()?.let { if (pending.keep(it)) setState(KeyboardState.Kept(null)) }
        }
        if (!switchToPreviousInputMethod()) {
            getSystemService(InputMethodManager::class.java).showInputMethodPicker()
        }
    }

    private fun openApp(reason: String) {
        startActivity(
            Intent(this, MainActivity::class.java)
                .putExtra(MainActivity.EXTRA_REASON, reason)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        )
    }

    private fun hasMicrophone(): Boolean =
        checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun setState(newState: KeyboardState) {
        state = newState
        render()
    }

    private fun render() {
        val status = statusView ?: return
        val mic = micButton ?: return
        val action = actionButton ?: return
        val discard = discardButton ?: return
        val macName = pairingStore.load()?.name ?: getString(R.string.your_mac)

        progress?.visibility = if (state == KeyboardState.Sending) View.VISIBLE else View.GONE
        mic.isEnabled = state != KeyboardState.Sending
        mic.isActivated = state == KeyboardState.Recording
        discard.visibility = if (state is KeyboardState.Kept) View.VISIBLE else View.GONE
        action.visibility = View.GONE

        val (icon, description) = when (state) {
            KeyboardState.Recording -> R.drawable.ic_stop to R.string.cd_stop
            is KeyboardState.Kept -> R.drawable.ic_retry to R.string.cd_retry
            KeyboardState.Sending -> R.drawable.ic_mic to R.string.cd_sending
            else -> R.drawable.ic_mic to R.string.cd_start
        }
        mic.setImageResource(icon)
        mic.contentDescription = getString(description)

        status.text = when (val s = state) {
            KeyboardState.Idle -> getString(R.string.status_idle)
            KeyboardState.Recording -> getString(R.string.status_recording)
            KeyboardState.Sending -> getString(R.string.status_sending, macName)
            KeyboardState.NoSpeech -> getString(R.string.status_no_speech)
            KeyboardState.RecorderFailed -> getString(R.string.status_recorder_failed)
            KeyboardState.NotPaired -> getString(R.string.status_not_paired).also { action.show(R.string.action_open_app) }
            KeyboardState.NeedsMicrophone -> getString(R.string.status_needs_mic).also { action.show(R.string.action_allow_mic) }
            is KeyboardState.Kept -> when (val e = s.error) {
                null -> when (s.reason) {
                    KeptReason.INTERRUPTED -> getString(R.string.status_kept)
                    KeptReason.FIELD_CHANGED -> getString(R.string.status_field_changed)
                    KeptReason.REJECTED -> getString(R.string.status_insert_rejected)
                }
                ApiError.Unreachable -> getString(R.string.error_unreachable)
                ApiError.Unauthorized -> getString(R.string.error_unauthorized).also { action.show(R.string.action_pair_again) }
                is ApiError.NoModelSelected -> getString(R.string.error_no_model)
                is ApiError.TranscriptionFailed -> getString(R.string.error_transcription_failed)
                is ApiError.Server -> getString(R.string.error_server, e.code ?: e.httpStatus.toString())
                is ApiError.InvalidResponse -> getString(R.string.error_invalid_response)
            }
        }
    }

    private fun Button.show(label: Int) {
        setText(label)
        visibility = View.VISIBLE
    }
}
