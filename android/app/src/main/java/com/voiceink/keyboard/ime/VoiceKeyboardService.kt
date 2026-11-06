package com.voiceink.keyboard.ime

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
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
    private sealed interface State {
        data object Idle : State
        data object Recording : State
        data object Sending : State
        data object NoSpeech : State

        /** A kept recording waits for a retry; [error] is null when it was only interrupted. */
        data class Kept(val error: ApiError?) : State
        data object NotPaired : State
        data object NeedsMicrophone : State
        data object RecorderFailed : State
    }

    private val scope: CoroutineScope = MainScope()
    private val client = VoiceInkClient()
    private lateinit var pairingStore: PairingStore
    private lateinit var pending: PendingRecording
    private lateinit var recorder: AudioRecorder

    private var state: State = State.Idle
    private var inputViewShown = false

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
                setState(State.Idle)
            }
        }
        root.findViewById<ImageButton>(R.id.switch_back).setOnClickListener { switchBack() }
        render()
        return root
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        inputViewShown = true
        if (state == State.Sending || state == State.Recording) return
        setState(restingState())
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        inputViewShown = false
        if (recorder.isRecording) {
            // Never send audio into a field the user has left; keep it for a retry instead.
            val file = recorder.stop()
            if (file != null && pending.keep(file)) setState(State.Kept(null)) else setState(State.Idle)
        }
        super.onFinishInputView(finishingInput)
    }

    /** What to show when nothing is in progress. */
    private fun restingState(): State = when {
        pairingStore.load() == null -> State.NotPaired
        !hasMicrophone() -> State.NeedsMicrophone
        pending.exists() -> (state as? State.Kept) ?: State.Kept(null)
        state == State.NoSpeech -> State.NoSpeech
        else -> State.Idle
    }

    private fun onMicTapped() {
        when (state) {
            State.Recording -> finishRecording()
            State.Sending -> Unit
            is State.Kept -> send()
            State.NotPaired -> openApp(MainActivity.REASON_PAIR)
            State.NeedsMicrophone -> openApp(MainActivity.REASON_MICROPHONE)
            State.Idle, State.NoSpeech, State.RecorderFailed -> startRecording()
        }
    }

    private fun onActionTapped() {
        when (val s = state) {
            State.NotPaired -> openApp(MainActivity.REASON_PAIR)
            State.NeedsMicrophone -> openApp(MainActivity.REASON_MICROPHONE)
            is State.Kept -> if (s.error == ApiError.Unauthorized) openApp(MainActivity.REASON_REJECTED) else send()
            else -> Unit
        }
    }

    private fun startRecording() {
        if (pairingStore.load() == null) return setState(State.NotPaired)
        if (!hasMicrophone()) return setState(State.NeedsMicrophone)
        try {
            recorder.start(pending.newScratchFile()) { if (state == State.Recording) finishRecording() }
            setState(State.Recording)
        } catch (_: Exception) {
            setState(State.RecorderFailed)
        }
    }

    private fun finishRecording() {
        val file = recorder.stop()
        if (file == null || !pending.keep(file)) return setState(State.NoSpeech)
        send()
    }

    private fun send() {
        val pairing = pairingStore.load() ?: return setState(State.NotPaired)
        if (!pending.exists()) return setState(State.Idle)
        setState(State.Sending)
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                client.transcribe(pairing, pending.file, "audio/mp4", pairingStore.lastHost)
            }
            onTranscribed(pairing, result)
        }
    }

    private fun onTranscribed(pairing: Pairing, result: ApiResult<Transcription>) {
        when (result) {
            is ApiResult.Failure -> setState(State.Kept(result.error))
            is ApiResult.Success -> {
                pairingStore.lastHost = result.host
                val connection = currentInputConnection
                if (!inputViewShown || connection == null) {
                    // The field is gone; keep the recording rather than typing somewhere else.
                    setState(State.Kept(null))
                    return
                }
                pending.discard()
                val text = result.value.text.trim()
                if (text.isEmpty()) return setState(State.NoSpeech)
                val before = connection.getTextBeforeCursor(1, 0)
                val separator = if (!before.isNullOrEmpty() && !before.last().isWhitespace()) " " else ""
                connection.commitText(separator + text, 1)
                setState(State.Idle)
                statusView?.text = getString(R.string.status_inserted, pairing.name)
                switchBack()
            }
        }
    }

    private fun switchBack() {
        if (recorder.isRecording) {
            recorder.stop()?.let { if (pending.keep(it)) setState(State.Kept(null)) }
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

    private fun setState(newState: State) {
        state = newState
        render()
    }

    private fun render() {
        val status = statusView ?: return
        val mic = micButton ?: return
        val action = actionButton ?: return
        val discard = discardButton ?: return
        val macName = pairingStore.load()?.name ?: getString(R.string.your_mac)

        progress?.visibility = if (state == State.Sending) View.VISIBLE else View.GONE
        mic.isEnabled = state != State.Sending
        mic.isActivated = state == State.Recording
        discard.visibility = if (state is State.Kept) View.VISIBLE else View.GONE
        action.visibility = View.GONE

        val (icon, description) = when (state) {
            State.Recording -> R.drawable.ic_stop to R.string.cd_stop
            is State.Kept -> R.drawable.ic_retry to R.string.cd_retry
            State.Sending -> R.drawable.ic_mic to R.string.cd_sending
            else -> R.drawable.ic_mic to R.string.cd_start
        }
        mic.setImageResource(icon)
        mic.contentDescription = getString(description)

        status.text = when (val s = state) {
            State.Idle -> getString(R.string.status_idle)
            State.Recording -> getString(R.string.status_recording)
            State.Sending -> getString(R.string.status_sending, macName)
            State.NoSpeech -> getString(R.string.status_no_speech)
            State.RecorderFailed -> getString(R.string.status_recorder_failed)
            State.NotPaired -> getString(R.string.status_not_paired).also { action.show(R.string.action_open_app) }
            State.NeedsMicrophone -> getString(R.string.status_needs_mic).also { action.show(R.string.action_allow_mic) }
            is State.Kept -> when (val e = s.error) {
                null -> getString(R.string.status_kept)
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
