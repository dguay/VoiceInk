package com.voiceink.keyboard.dictation

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
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
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Record → send to the Mac → type into the field the recording was made for, shared by the voice
 * keyboard and the mic bubble. The recording is kept in [pending] until its text is in that field,
 * so a failure or a field change leaves it for Retry; [delivery] tracks which field that is.
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

        /** The text was typed into its field. */
        fun onInserted(pairing: Pairing)
    }

    private val pairingStore = PairingStore(context)
    private val client = VoiceInkClient()
    private val recorder = AudioRecorder(context)
    private val delivery = TextDelivery()

    var state: DictationState = DictationState.Idle
        private set

    val macName: String get() = pairingStore.load()?.name ?: context.getString(R.string.your_mac)
    val isPaired: Boolean get() = pairingStore.load() != null
    val hasKeptRecording: Boolean get() = pending.exists()
    val hasMicrophone: Boolean
        get() = context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    /** A field gained the entry point; see [TextDelivery.startSession]. */
    fun startSession(sameField: Boolean = false) = delivery.startSession(sameField)

    /** The field was left; a request still in flight keeps its recording instead of typing. */
    fun endSession() = delivery.endSession()

    fun show(newState: DictationState) {
        state = newState
        host.onStateChanged(newState)
    }

    /** The resting state for a fresh appearance on a field, without starting anything. */
    fun restingState(): DictationState =
        DictationState.resting(state, isPaired, hasMicrophone, hasKeptRecording)

    fun onMicTapped() {
        when (state) {
            DictationState.Recording -> finishRecording()
            DictationState.Sending -> Unit
            is DictationState.Kept -> send()
            DictationState.NotPaired -> openApp(MainActivity.REASON_PAIR)
            DictationState.NeedsMicrophone -> openApp(MainActivity.REASON_MICROPHONE)
            DictationState.Idle, DictationState.NoSpeech, DictationState.RecorderFailed -> startRecording()
        }
    }

    fun onActionTapped() {
        when (val s = state) {
            DictationState.NotPaired -> openApp(MainActivity.REASON_PAIR)
            DictationState.NeedsMicrophone -> openApp(MainActivity.REASON_MICROPHONE)
            is DictationState.Kept -> if (s.error == ApiError.Unauthorized) openApp(MainActivity.REASON_REJECTED) else send()
            else -> Unit
        }
    }

    fun discard() {
        pending.discard()
        show(DictationState.Idle)
    }

    fun startRecording() {
        if (!isPaired) return show(DictationState.NotPaired)
        if (!hasMicrophone) return show(DictationState.NeedsMicrophone)
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

    private fun send() {
        val pairing = pairingStore.load() ?: return show(DictationState.NotPaired)
        if (!pending.exists()) return show(DictationState.Idle)
        show(DictationState.Sending)
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
            is ApiResult.Failure -> show(DictationState.Kept(result.error))
            is ApiResult.Success -> {
                pairingStore.lastHost = result.host
                host.beforeDelivery()
                when (delivery.deliver(ticket, result.value.text.trim(), host::commit, pending::discard)) {
                    TextDelivery.Outcome.INSERTED -> {
                        show(DictationState.Idle)
                        host.onInserted(pairing)
                    }
                    TextDelivery.Outcome.EMPTY -> show(DictationState.NoSpeech)
                    TextDelivery.Outcome.FIELD_CHANGED -> show(DictationState.Kept(null, KeptReason.FIELD_CHANGED))
                    TextDelivery.Outcome.REJECTED -> show(DictationState.Kept(null, KeptReason.REJECTED))
                }
            }
        }
    }

    private fun openApp(reason: String) {
        context.startActivity(
            Intent(context, MainActivity::class.java)
                .putExtra(MainActivity.EXTRA_REASON, reason)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        )
    }
}
