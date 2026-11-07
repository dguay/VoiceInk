package com.voiceink.keyboard.bubble

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.view.ContextThemeWrapper
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.Button
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import com.voiceink.keyboard.R
import com.voiceink.keyboard.dictation.DictationFlow
import com.voiceink.keyboard.dictation.DictationMessages
import com.voiceink.keyboard.dictation.DictationState

/**
 * The bubble's overlay window: a round mic button and, whenever there is something to say, a card
 * above it with the status and Retry / Discard or the action that unblocks dictation. It never
 * takes focus, so the keyboard and the field stay as they were. Dragging the mic moves the bubble
 * and remembers where it was dropped, relative to the keyboard.
 */
internal class MicBubbleView(
    private val context: Context,
    private val flow: DictationFlow,
    private val settings: BubbleSettings,
) {
    private val windowManager = context.getSystemService(WindowManager::class.java)

    @SuppressLint("InflateParams") // An overlay window has no parent.
    private val root: LinearLayout = LayoutInflater.from(ContextThemeWrapper(context, R.style.Theme_VoiceInk))
        .inflate(R.layout.mic_bubble, null) as LinearLayout
    private val card: View = root.findViewById(R.id.bubble_card)
    private val status: TextView = root.findViewById(R.id.bubble_status)
    private val discard: Button = root.findViewById(R.id.bubble_discard)
    private val action: Button = root.findViewById(R.id.bubble_action)
    private val mic: ImageButton = root.findViewById(R.id.bubble_mic)
    private val progress: ProgressBar = root.findViewById(R.id.bubble_progress)

    private val params = WindowManager.LayoutParams(
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) setFitInsetsTypes(0)
        title = context.getString(R.string.bubble_service_label)
    }

    private var attached = false
    private var keyboardTop = 0
    private var field: Box? = null
    private var drag: Drag? = null
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop

    /** A touch on the mic that started at raw ([x], [y]) with the window at ([windowX], [windowY]). */
    private class Drag(val x: Float, val y: Float, val windowX: Int, val windowY: Int) {
        var moving = false
    }

    init {
        allowDragging()
        mic.setOnClickListener { flow.onMicTapped() }
        action.setOnClickListener { flow.onActionTapped() }
        discard.setOnClickListener { flow.discard() }
    }

    /** Shows the bubble docked above a keyboard whose top edge is at [keyboardTop], clear of [field]. */
    fun show(keyboardTop: Int, field: Box) {
        this.keyboardTop = keyboardTop
        this.field = field
        render()
    }

    fun hide() {
        field = null
        drag = null
        if (attached) {
            windowManager.removeViewImmediate(root)
            attached = false
        }
    }

    fun render() {
        val field = field ?: return
        val state = flow.state

        progress.visibility = if (state == DictationState.Sending) View.VISIBLE else View.GONE
        mic.isEnabled = state != DictationState.Sending
        mic.isActivated = state == DictationState.Recording
        val (icon, description) = when (state) {
            DictationState.Recording -> R.drawable.ic_stop to R.string.cd_stop
            is DictationState.Kept -> R.drawable.ic_retry to R.string.cd_retry
            DictationState.Sending -> R.drawable.ic_mic to R.string.cd_sending
            else -> R.drawable.ic_mic to R.string.cd_start
        }
        mic.setImageResource(icon)
        mic.contentDescription = context.getString(description)

        card.visibility = if (state == DictationState.Idle) View.GONE else View.VISIBLE
        status.text = DictationMessages.status(context, state, flow.macName)
        discard.visibility = if (state is DictationState.Kept) View.VISIBLE else View.GONE
        val label = DictationMessages.action(state) ?: if (state is DictationState.Kept) R.string.action_retry else null
        if (label != null) {
            action.setText(label)
            action.visibility = View.VISIBLE
        } else {
            action.visibility = View.GONE
        }

        place(field)
    }

    private fun place(field: Box) {
        // The finger holds the bubble; it lands where it is dropped.
        if (drag?.moving == true) return
        val rtl = context.resources.configuration.layoutDirection == View.LAYOUT_DIRECTION_RTL
        val unspecified = View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
        root.measure(unspecified, unspecified)
        val area = area()
        val box = BubblePlacement.place(
            area = area,
            position = settings.position,
            field = field,
            width = root.measuredWidth,
            height = root.measuredHeight,
            margin = margin(),
            rtl = rtl,
        )
        // The card lines up with the mic on whichever side the bubble sits.
        val onEndSide = (box.left + box.right) / 2 > (area.left + area.right) / 2 != rtl
        root.gravity = if (onEndSide) Gravity.END else Gravity.START
        move(box)
    }

    // Taps, including accessibility clicks, still reach the mic's own performClick.
    @SuppressLint("ClickableViewAccessibility")
    private fun allowDragging() = mic.setOnTouchListener(::onMicTouch)

    /** Taps fall through to the mic's click listener; a move past the touch slop drags the bubble instead. */
    private fun onMicTouch(view: View, event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> drag = Drag(event.rawX, event.rawY, params.x, params.y)
            MotionEvent.ACTION_MOVE -> {
                val drag = drag ?: return false
                val dx = event.rawX - drag.x
                val dy = event.rawY - drag.y
                if (!drag.moving) {
                    if (dx * dx + dy * dy < touchSlop * touchSlop) return false
                    drag.moving = true
                    view.isPressed = false
                    view.cancelLongPress()
                }
                move(BubblePlacement.clamp(area(), drag.windowX + dx.toInt(), drag.windowY + dy.toInt(), root.width, root.height, margin()))
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                val drag = drag ?: return false
                this.drag = null
                if (!drag.moving) return false
                val box = Box(params.x, params.y, params.x + root.width, params.y + root.height)
                settings.position = BubblePlacement.positionOf(area(), box, margin())
                render()
                return true
            }
        }
        return false
    }

    /**
     * The part of the screen the bubble may use: clear of the status bar, cutouts and side navigation
     * bars, and above the keyboard.
     */
    private fun area(): Box {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val metrics = windowManager.maximumWindowMetrics
            val insets = metrics.windowInsets.getInsetsIgnoringVisibility(
                WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout(),
            )
            val bounds = metrics.bounds
            return Box(bounds.left + insets.left, bounds.top + insets.top, bounds.right - insets.right, keyboardTop)
        }
        return Box(0, 0, context.resources.displayMetrics.widthPixels, keyboardTop)
    }

    private fun margin() = (MARGIN_DP * context.resources.displayMetrics.density).toInt()

    private fun move(box: Box) {
        params.x = box.left
        params.y = box.top
        if (attached) {
            windowManager.updateViewLayout(root, params)
        } else {
            windowManager.addView(root, params)
            attached = true
        }
    }

    private companion object {
        const val MARGIN_DP = 8
    }
}
