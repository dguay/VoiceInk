package com.voiceink.keyboard.ime

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
import com.voiceink.keyboard.api.Pairing
import com.voiceink.keyboard.dictation.DictationFlow
import com.voiceink.keyboard.dictation.DictationMessages
import com.voiceink.keyboard.dictation.DictationState
import com.voiceink.keyboard.dictation.TextInsertion
import com.voiceink.keyboard.store.PendingRecording
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel

/**
 * A voice-only keyboard: one mic button and a status line. A finished recording is sent to the
 * paired Mac, the returned text is inserted at the cursor and the previous keyboard comes back.
 */
class VoiceKeyboardService : InputMethodService(), DictationFlow.Host {
    private val scope: CoroutineScope = MainScope()
    private lateinit var flow: DictationFlow

    private var statusView: TextView? = null
    private var micButton: ImageButton? = null
    private var progress: ProgressBar? = null
    private var actionButton: Button? = null
    private var discardButton: Button? = null

    override fun onCreate() {
        super.onCreate()
        flow = DictationFlow(this, scope, PendingRecording(this), this)
    }

    override fun onDestroy() {
        flow.close()
        scope.cancel()
        super.onDestroy()
    }

    override fun onEvaluateFullscreenMode(): Boolean = false

    // An input view has no parent until the framework attaches it.
    @android.annotation.SuppressLint("InflateParams")
    override fun onCreateInputView(): View {
        val root = layoutInflater.inflate(R.layout.keyboard, null)
        statusView = root.findViewById(R.id.status)
        micButton = root.findViewById<ImageButton>(R.id.mic).apply { setOnClickListener { flow.onMicTapped() } }
        progress = root.findViewById(R.id.progress)
        actionButton = root.findViewById<Button>(R.id.action).apply { setOnClickListener { flow.onActionTapped() } }
        discardButton = root.findViewById<Button>(R.id.discard).apply { setOnClickListener { flow.discard() } }
        root.findViewById<ImageButton>(R.id.switch_back).setOnClickListener { switchBack() }
        render()
        return root
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        flow.startSession(sameField = restarting)
        val opening = KeyboardOpening.decide(
            current = flow.state,
            restarting = restarting,
            textField = info != null && info.inputType != InputType.TYPE_NULL,
            paired = flow.isPaired,
            hasMicrophone = flow.hasMicrophone,
            hasKeptRecording = flow.hasKeptRecording,
        )
        flow.show(opening.state)
        if (opening.startRecording) flow.startRecording()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        flow.endSession()
        flow.interrupt()
        super.onFinishInputView(finishingInput)
    }

    override fun onFinishInput() {
        // The editor connection ended (field or app changed), even if the view stays up.
        flow.endSession()
        super.onFinishInput()
    }

    override fun onStateChanged(state: DictationState) = render()

    override fun onInserted(pairing: Pairing) {
        statusView?.text = getString(R.string.status_inserted, pairing.name)
        switchBack()
    }

    /** Types [text] at the cursor, separated from a preceding word by a space. */
    override fun commit(text: String): Boolean {
        val connection = currentInputConnection ?: return false
        val before = connection.getTextBeforeCursor(1, 0)
        return connection.commitText(TextInsertion.separator(before) + text, 1)
    }

    private fun switchBack() {
        flow.interrupt()
        if (!switchToPreviousInputMethod()) {
            getSystemService(InputMethodManager::class.java).showInputMethodPicker()
        }
    }

    private fun render() {
        val status = statusView ?: return
        val mic = micButton ?: return
        val action = actionButton ?: return
        val discard = discardButton ?: return
        val state = flow.state

        progress?.visibility = if (state == DictationState.Sending) View.VISIBLE else View.GONE
        mic.isEnabled = state != DictationState.Sending
        mic.isActivated = state == DictationState.Recording
        discard.visibility = if (state is DictationState.Kept) View.VISIBLE else View.GONE

        val (icon, description) = when (state) {
            DictationState.Recording -> R.drawable.ic_stop to R.string.cd_stop
            is DictationState.Kept -> R.drawable.ic_retry to R.string.cd_retry
            DictationState.Sending -> R.drawable.ic_mic to R.string.cd_sending
            else -> R.drawable.ic_mic to R.string.cd_start
        }
        mic.setImageResource(icon)
        mic.contentDescription = getString(description)

        status.text = DictationMessages.status(this, state, flow.macName)
        val label = DictationMessages.action(state)
        if (label != null) {
            action.setText(label)
            action.visibility = View.VISIBLE
        } else {
            action.visibility = View.GONE
        }
    }
}
