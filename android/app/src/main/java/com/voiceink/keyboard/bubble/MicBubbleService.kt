package com.voiceink.keyboard.bubble

import android.accessibilityservice.AccessibilityService
import android.content.SharedPreferences
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import com.voiceink.keyboard.api.AppLabel
import com.voiceink.keyboard.api.FieldContext
import com.voiceink.keyboard.api.Pairing
import com.voiceink.keyboard.corrections.CorrectionHandoff
import com.voiceink.keyboard.corrections.InsertedDictation
import com.voiceink.keyboard.dictation.DictationFlow
import com.voiceink.keyboard.dictation.DictationState
import com.voiceink.keyboard.dictation.TextInsertion
import com.voiceink.keyboard.store.PendingRecording
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel

/**
 * Shows a floating mic over any open keyboard and types the dictation into the field the keyboard
 * was opened for, through the same flow as the voice keyboard. It only looks at which windows are
 * open and which field has input focus, and, after a dictation, at that field until the user leaves
 * it ([CorrectionWatcher]).
 */
class MicBubbleService : AccessibilityService(), DictationFlow.Host {
    private val handler = Handler(Looper.getMainLooper())
    private val refresh = Runnable { update() }
    private var scope: CoroutineScope? = null
    private var flow: DictationFlow? = null
    private var bubble: MicBubbleView? = null
    private var settings: BubbleSettings? = null
    private var corrections: CorrectionWatcher? = null
    /** Where the bubble's last dictation starts in its field. */
    private var lastInsertStart: Int? = null
    private val steadiness = Steadiness<Pair<Int, Box>>()
    // A new exclusion or a reset position applies at once, even with the bubble on screen.
    private val settingsChanged = SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> handler.post(refresh) }
    private val sessions = FieldSessions<AccessibilityNodeInfo>(
        start = { flow?.startSession() },
        end = { flow?.endSession() },
    )

    override fun onServiceConnected() {
        super.onServiceConnected()
        val scope = MainScope().also { scope = it }
        val flow = DictationFlow(this, scope, PendingRecording(this, BUBBLE_RECORDINGS), this).also { flow = it }
        val settings = BubbleSettings(this).also { settings = it }
        settings.registerListener(settingsChanged)
        bubble = MicBubbleView(this, flow, settings)
        corrections = CorrectionWatcher(this, handler, scope) { keyboardOpen(keyboardWindow()) }.also { it.start() }
        update()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // Rotation: re-place the bubble against the new screen and keyboard.
        handler.removeCallbacks(refresh)
        handler.postDelayed(refresh, SETTLE_MS)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        handler.removeCallbacks(refresh)
        // A keyboard sliding away (Back, or leaving the app) takes the bubble with it right away.
        if (event?.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED && !keyboardOpen(keyboardWindow())) return update()
        // Focus and window events arrive in bursts; look at the screen once they settle.
        handler.postDelayed(refresh, SETTLE_MS)
    }

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        handler.removeCallbacks(refresh)
        corrections?.stop()
        settings?.unregisterListener(settingsChanged)
        sessions.update(null)
        flow?.close()
        bubble?.hide()
        scope?.cancel()
        super.onDestroy()
    }

    private fun update() {
        val flow = flow ?: return
        val bubble = bubble ?: return
        val keyboard = keyboardWindow()
        val focus = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        val visible = BubbleVisibility.shouldShow(
            keyboardShown = keyboardOpen(keyboard),
            ownKeyboard = keyboard?.root?.packageName?.toString() == packageName,
            field = focus?.let {
                FocusedField(editable = it.isEditable, password = it.isPassword, app = it.packageName?.toString())
            },
            excludedApps = settings?.excludedApps.orEmpty(),
        )
        val fieldChanged = sessions.update(if (visible) focus else null)
        // Never send audio into a field the user has left: keep it for Retry instead.
        if (fieldChanged) flow.interrupt()
        if (!visible || keyboard == null || focus == null) {
            steadiness.reset()
            return bubble.hide()
        }

        if (fieldChanged && !flow.state.isBusy) flow.show(flow.restingState(sameField = false))
        val keyboardTop = Rect().also(keyboard::getBoundsInScreen).top
        val field = focus.screenBox()
        // Still opening or resizing: look again shortly rather than show the bubble on the way.
        if (!steadiness.look(keyboardTop to field, SystemClock.uptimeMillis())) {
            handler.removeCallbacks(refresh)
            handler.postDelayed(refresh, STEADY_MS)
            return
        }
        bubble.show(keyboardTop = keyboardTop, field = field)
    }

    private fun keyboardWindow(): AccessibilityWindowInfo? =
        windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }

    private fun keyboardOpen(keyboard: AccessibilityWindowInfo?): Boolean {
        val bounds = keyboard?.let { Rect().also(it::getBoundsInScreen) } ?: return false
        val screenBottom = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            getSystemService(WindowManager::class.java).maximumWindowMetrics.bounds.bottom
        } else {
            Int.MAX_VALUE // Android 10: no reliable screen size here; wait for the keyboard to go.
        }
        return BubbleVisibility.keyboardAtRest(Box(bounds.left, bounds.top, bounds.right, bounds.bottom), screenBottom)
    }

    /** Focus or keyboard events may still be settling; look now so the text cannot reach a field left meanwhile. */
    override fun beforeDelivery() {
        handler.removeCallbacks(refresh)
        update()
    }

    override fun onStateChanged(state: DictationState) {
        bubble?.render()
    }

    /** Replaces the field's selection with [text] (or inserts it at the cursor) and moves the cursor after it. */
    override fun commit(text: String): Boolean {
        val node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (node == null || node != sessions.current || !node.isEditable || node.isPassword) {
            // Focus moved since the last look; keep the text out of that field and catch up.
            handler.post(refresh)
            return false
        }
        val existing = if (node.isShowingHintText) "" else node.text?.toString().orEmpty()
        val edit = TextInsertion.insert(existing, node.textSelectionStart, node.textSelectionEnd, text)
        val setText = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, edit.text)
        }
        if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, setText)) return false
        lastInsertStart = edit.cursor - text.length
        val cursor = Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, edit.cursor)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, edit.cursor)
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, cursor)
        return true
    }

    override fun onInserted(pairing: Pairing?) = Unit

    /** The field the bubble types into, as last seen with input focus. */
    override fun fieldContext(): FieldContext? =
        sessions.current?.let {
            FieldContext.of(it.packageName, it.inputType, it.isPassword, AppLabel.of(packageManager, it.packageName))
        }

    override fun onDelivered(historyId: String?, text: String) {
        historyId ?: return
        CorrectionHandoff.inserted(InsertedDictation(historyId, text, lastInsertStart))
    }

    private fun AccessibilityNodeInfo.screenBox(): Box {
        val r = Rect().also(::getBoundsInScreen)
        return Box(r.left, r.top, r.right, r.bottom)
    }

    private companion object {
        const val BUBBLE_RECORDINGS = "bubble"
        const val SETTLE_MS = 80L
        const val STEADY_MS = 100L
    }
}
