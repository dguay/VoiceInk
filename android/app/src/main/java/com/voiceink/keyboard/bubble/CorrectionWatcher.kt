package com.voiceink.keyboard.bubble

import android.accessibilityservice.AccessibilityService
import android.os.Handler
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import com.voiceink.keyboard.api.ApiResult
import com.voiceink.keyboard.api.CorrectionSnapshot
import com.voiceink.keyboard.api.VoiceInkClient
import com.voiceink.keyboard.corrections.CorrectionHandoff
import com.voiceink.keyboard.corrections.CorrectionSending
import com.voiceink.keyboard.corrections.CorrectionWindow
import com.voiceink.keyboard.corrections.FieldObservation
import com.voiceink.keyboard.corrections.Focus
import com.voiceink.keyboard.corrections.InsertLocator
import com.voiceink.keyboard.corrections.InsertedDictation
import com.voiceink.keyboard.corrections.PasswordFields
import com.voiceink.keyboard.store.PairingStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * After a dictation is typed (by the voice keyboard or the bubble), watches its field until the
 * user is done with it ([FieldObservation]) and sends the Mac the window around the dictation
 * ([CorrectionWindow]), so Auto-Learn learns from the corrections made on the phone. Everything
 * stays in memory; a snapshot that cannot be sent after a few attempts is dropped.
 */
internal class CorrectionWatcher(
    private val service: AccessibilityService,
    private val handler: Handler,
    private val scope: CoroutineScope,
    private val keyboardOpen: () -> Boolean,
) : CorrectionHandoff.Listener {
    private class Watch(
        val dictation: InsertedDictation,
        val field: AccessibilityNodeInfo,
        val afterInsert: String,
        val start: Int,
        val observation: FieldObservation,
    )

    private val pairingStore = PairingStore(service)
    private val client = VoiceInkClient()
    private var watch: Watch? = null
    private val tick = Runnable { look() }

    fun start() = CorrectionHandoff.register(this)

    /** The service is going away: stop watching and drop what was not sent. */
    fun stop() {
        CorrectionHandoff.unregister(this)
        handler.removeCallbacks(tick)
        watch = null
    }

    override fun onInserted(dictation: InsertedDictation) {
        handler.post {
            // A new dictation ends the previous observation as it stood at its last look.
            watch?.let { finish(it, FieldObservation.Decision.FIELD_CHANGED) }
            // Give the editor a moment to show the text before it is read back.
            handler.postDelayed({ begin(dictation) }, SETTLE_MS)
        }
    }

    private fun begin(dictation: InsertedDictation) {
        val field = service.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return
        if (!field.isEditable || PasswordFields.isPassword(field.isPassword, field.inputType) || field.isShowingHintText) return
        val text = field.text?.toString() ?: return
        val start = InsertLocator.locate(text, dictation.text, dictation.start) ?: return
        val observation = FieldObservation(SystemClock.uptimeMillis())
        observation.look(SystemClock.uptimeMillis(), Focus.ON_FIELD, password = false, keyboardOpen = true, fieldText = text)
        watch = Watch(dictation, field, text, start, observation)
        handler.removeCallbacks(tick)
        handler.postDelayed(tick, FieldObservation.LOOK_INTERVAL_MS)
    }

    private fun look() {
        val watch = watch ?: return
        val focused = service.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        val focus = when {
            focused == null -> Focus.NONE
            focused == watch.field -> Focus.ON_FIELD
            else -> Focus.OTHER_FIELD
        }
        val onField = if (focus == Focus.ON_FIELD) focused else null
        val decision = watch.observation.look(
            now = SystemClock.uptimeMillis(),
            focus = focus,
            password = onField != null && PasswordFields.isPassword(onField.isPassword, onField.inputType),
            keyboardOpen = keyboardOpen(),
            fieldText = onField?.takeUnless { it.isShowingHintText }?.text?.toString(),
        )
        if (decision == FieldObservation.Decision.WATCH) {
            handler.postDelayed(tick, FieldObservation.LOOK_INTERVAL_MS)
        } else {
            finish(watch, decision)
        }
    }

    private fun finish(watch: Watch, decision: FieldObservation.Decision) {
        handler.removeCallbacks(tick)
        if (this.watch === watch) this.watch = null
        if (!decision.sends) return
        val whenLeft = watch.observation.lastText ?: return
        val snapshot = CorrectionWindow.cut(watch.dictation.historyId, watch.dictation.text, watch.afterInsert, whenLeft, watch.start)
            ?: return
        send(snapshot)
    }

    private fun send(snapshot: CorrectionSnapshot) {
        val pairing = pairingStore.load() ?: return
        val preferredHost = pairingStore.lastHost
        scope.launch {
            var attempt = 1
            while (true) {
                val result = withContext(Dispatchers.IO) { client.submitCorrection(pairing, snapshot, preferredHost) }
                if (result is ApiResult.Success) return@launch
                val error = (result as ApiResult.Failure).error
                if (!CorrectionSending.shouldRetry(attempt, error)) return@launch // Dropped.
                attempt++
                delay(CorrectionSending.RETRY_DELAY_MS)
            }
        }
    }

    private companion object {
        const val SETTLE_MS = 250L
    }
}
