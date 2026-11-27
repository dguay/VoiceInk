package com.voiceink.keyboard.dictation

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.widget.Toast
import com.voiceink.keyboard.R
import com.voiceink.keyboard.api.ApiError
import com.voiceink.keyboard.api.ApiResult
import com.voiceink.keyboard.api.FieldContext
import com.voiceink.keyboard.api.Pairing
import com.voiceink.keyboard.api.Transcription
import com.voiceink.keyboard.api.VoiceInkClient
import com.voiceink.keyboard.offline.OfflineModelStore
import com.voiceink.keyboard.offline.OfflineSettings
import com.voiceink.keyboard.offline.OnDeviceTranscriber
import com.voiceink.keyboard.offline.PhoneResult
import com.voiceink.keyboard.setup.MainActivity
import com.voiceink.keyboard.store.PairingStore
import com.voiceink.keyboard.store.PendingRecording
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Record → transcribe → type into the field the recording was made for, shared by the voice
 * keyboard and the mic bubble. The paired Mac transcribes unless Offline mode is on or no Mac is
 * set up; the on-device model takes over then, and after the Mac is unreachable when the user turned
 * on automatic fallback or taps Transcribe on phone ([TranscriptionRoute]). The recording is kept in
 * [pending] until its text is in that field, so a failure or a field change leaves it for Retry;
 * [delivery] tracks which field that is.
 */
class DictationFlow internal constructor(
    private val context: Context,
    private val scope: CoroutineScope,
    private val pending: PendingRecording,
    private val host: Host,
) {
    /** The entry point that shows the state and owns the field. Called on the main thread. */
    interface Host {
        fun onStateChanged(state: DictationState)

        /** Brings the field sessions up to date just before a transcription is delivered. */
        fun beforeDelivery() = Unit

        /** Types [text] at the cursor of the current field; false when the editor rejected it. */
        fun commit(text: String): Boolean

        /** The text was typed into its field, transcribed by the [pairing] Mac, or on the phone when null. */
        fun onInserted(pairing: Pairing?)

        /**
         * The app and kind of the field the text will go to, sent to the Mac to pick the mode;
         * null when no field is known. Every entry point must say, so it has no default.
         */
        fun fieldContext(): FieldContext?

        /** [text] was just typed for the History entry [historyId] (null from a Mac that sends none), before [onInserted]. */
        fun onDelivered(historyId: String?, text: String) = Unit
    }

    private val pairingStore = PairingStore(context)
    private val client = VoiceInkClient()
    private val recorder = AudioRecorder(context)
    private val delivery = TextDelivery()
    private val offlineModel = OfflineModelStore(context)
    private val offlineSettings = OfflineSettings(context)

    var state: DictationState = DictationState.Idle
        private set

    val macName: String get() = pairingStore.load()?.name ?: context.getString(R.string.your_mac)
    val isPaired: Boolean get() = pairingStore.load() != null
    val hasKeptRecording: Boolean get() = pending.exists()
    val hasMicrophone: Boolean
        get() = context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    /** What setup still needs before dictating, or null; see [TranscriptionRoute.blocker]. */
    val blocker: DictationState?
        get() = TranscriptionRoute.blocker(isPaired, offlineSettings.offlineMode, offlineModel.isReady, hasMicrophone)

    /** The current kept recording can be transcribed on the phone instead. */
    val phoneOffered: Boolean get() = TranscriptionRoute.offersPhone(state, offlineModel.isReady)

    /** A field gained the entry point; see [TextDelivery.startSession]. */
    fun startSession(sameField: Boolean = false) = delivery.startSession(sameField)

    /** The field was left; a request still in flight keeps its recording instead of typing. */
    fun endSession() = delivery.endSession()

    fun show(newState: DictationState) {
        state = newState
        host.onStateChanged(newState)
    }

    /** The resting state for an appearance on a field (a [sameField] restart, or a new one), without starting anything. */
    fun restingState(sameField: Boolean): DictationState =
        DictationState.resting(state, blocker, hasKeptRecording, sameField)

    fun onMicTapped() {
        when (state) {
            DictationState.Recording -> finishRecording()
            DictationState.Sending, DictationState.TranscribingOnPhone -> Unit
            is DictationState.Kept -> send()
            DictationState.NotPaired -> openApp(MainActivity.REASON_PAIR)
            DictationState.NeedsOfflineModel -> openApp(MainActivity.REASON_OFFLINE_MODEL)
            DictationState.NeedsMicrophone -> openApp(MainActivity.REASON_MICROPHONE)
            DictationState.Idle, DictationState.NoSpeech, DictationState.InsertedOnPhone, DictationState.RecorderFailed ->
                startRecording()
        }
    }

    fun onActionTapped() {
        when (val s = state) {
            DictationState.NotPaired -> openApp(MainActivity.REASON_PAIR)
            DictationState.NeedsOfflineModel -> openApp(MainActivity.REASON_OFFLINE_MODEL)
            DictationState.NeedsMicrophone -> openApp(MainActivity.REASON_MICROPHONE)
            is DictationState.Kept -> when {
                s.error == ApiError.Unauthorized -> openApp(MainActivity.REASON_REJECTED)
                s.reason == KeptReason.PHONE_MODEL_MISSING -> openApp(MainActivity.REASON_OFFLINE_MODEL)
                phoneOffered -> transcribeOnPhone(delivery.ticket())
                else -> send()
            }
            else -> Unit
        }
    }

    fun discard() {
        pending.discard()
        show(DictationState.Idle)
    }

    /** Copies the rejected transcription to the Android clipboard and clears the pending error state. */
    fun copyKeptText(): Boolean {
        val next = CopyFallback.copy(state, ::copyToClipboard, pending::discard)
        if (next === state) return false
        show(next)
        return true
    }

    fun startRecording() {
        blocker?.let { return show(it) }
        try {
            recorder.start(pending.newScratchFile()) { if (state == DictationState.Recording) finishRecording() }
            show(DictationState.Recording)
        } catch (_: Exception) {
            show(DictationState.RecorderFailed)
        }
    }

    /** Stops a recording in progress without sending it: never send audio into a field the user left. */
    fun interrupt() {
        if (!recorder.isRecording) return
        val file = recorder.stop()
        show(if (file != null && pending.keep(file)) DictationState.Kept(null) else DictationState.Idle)
    }

    /** The entry point is going away; keep any recording in progress for a later retry. */
    fun close() {
        recorder.stop()?.let { pending.keep(it) }
    }

    private fun finishRecording() {
        val file = recorder.stop()
        if (file == null || !pending.keep(file)) return show(DictationState.NoSpeech)
        send()
    }

    /** Transcribes the kept recording where [TranscriptionRoute.engine] says. */
    private fun send() {
        val pairing = pairingStore.load()
        when (TranscriptionRoute.engine(pairing != null, offlineSettings.offlineMode, offlineModel.isReady)) {
            null -> show(blocker ?: DictationState.NotPaired)
            Engine.PHONE -> transcribeOnPhone(delivery.ticket())
            Engine.MAC -> sendToMac(pairing ?: return show(DictationState.NotPaired))
        }
    }

    private fun sendToMac(pairing: Pairing) {
        if (!pending.exists()) return show(DictationState.Idle)
        show(DictationState.Sending)
        val ticket = delivery.ticket()
        val field = host.fieldContext()
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                client.transcribe(pairing, pending.file, "audio/mp4", pairingStore.lastHost, field)
            }
            onTranscribed(pairing, ticket, result)
        }
    }

    private fun onTranscribed(pairing: Pairing, ticket: TextDelivery.Ticket, result: ApiResult<Transcription>) {
        when (result) {
            is ApiResult.Failure ->
                if (TranscriptionRoute.fallBackAutomatically(result.error, offlineSettings.autoFallback, offlineModel.isReady)) {
                    transcribeOnPhone(ticket)
                } else {
                    show(DictationState.Kept(result.error))
                }
            is ApiResult.Success -> {
                pairingStore.lastHost = result.host
                host.beforeDelivery()
                val text = result.value.text.trim()
                val outcome = delivery.deliver(ticket, text, host::commit, pending::discard)
                show(CopyFallback.stateAfterDelivery(outcome, text))
                if (outcome == TextDelivery.Outcome.INSERTED) {
                    host.onDelivered(result.value.id, text)
                    host.onInserted(pairing)
                }
            }
        }
    }

    /**
     * Transcribes the kept recording with the on-device model and types it into the field [ticket]
     * was handed out for. Nothing reaches the Mac, so its History, corrections and cleanup are skipped.
     */
    private fun transcribeOnPhone(ticket: TextDelivery.Ticket) {
        if (!pending.exists()) return show(DictationState.Idle)
        show(DictationState.TranscribingOnPhone)
        scope.launch {
            when (val result = OnDeviceTranscriber.transcribe(context, pending.file)) {
                is PhoneResult.Failed -> show(TranscriptionRoute.stateAfterPhoneFailure(result.failure))
                is PhoneResult.Text -> {
                    host.beforeDelivery()
                    val text = result.text.trim()
                    val outcome = delivery.deliver(ticket, text, host::commit, pending::discard)
                    show(TranscriptionRoute.stateAfterPhoneDelivery(outcome, text))
                    if (outcome == TextDelivery.Outcome.INSERTED) host.onInserted(null)
                }
            }
        }
    }

    private fun copyToClipboard(text: String): Boolean = try {
        val clipboard = context.getSystemService(ClipboardManager::class.java) ?: return false
        clipboard.setPrimaryClip(ClipData.newPlainText(context.getString(R.string.clipboard_label), text))
        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.S_V2) {
            Toast.makeText(context, R.string.copied_to_clipboard, Toast.LENGTH_SHORT).show()
        }
        true
    } catch (_: RuntimeException) {
        false
    }

    private fun openApp(reason: String) {
        context.startActivity(
            Intent(context, MainActivity::class.java)
                .putExtra(MainActivity.EXTRA_REASON, reason)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        )
    }
}
