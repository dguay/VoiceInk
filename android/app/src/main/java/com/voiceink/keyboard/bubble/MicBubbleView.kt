package com.voiceink.keyboard.bubble

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.ContextThemeWrapper
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import com.voiceink.keyboard.R
import com.voiceink.keyboard.dictation.CopyFallback
import com.voiceink.keyboard.dictation.DictationFlow
import com.voiceink.keyboard.dictation.DictationMessages
import com.voiceink.keyboard.dictation.DictationState

/**
 * The bubble's overlay window: a round mic button and, whenever there is something to say, a card
 * above it with the status and Retry / Copy / Discard or the action that unblocks dictation. When
 * idle auto-collapse is enabled and the bubble sits untouched, it tucks against the nearest screen
 * edge as a slim handle until tapped. It never takes focus, so the keyboard and the field stay as
 * they were. Dragging the mic moves the bubble and remembers where it was dropped, relative to the
 * keyboard.
 */
internal class MicBubbleView(
    private val context: Context,
    private val flow: DictationFlow,
    private val settings: BubbleSettings,
) {
    private val windowManager = context.getSystemService(WindowManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val idleCollapse = BubbleIdleCollapse()
    private val collapseTimer = Runnable { onCollapseTimer() }

    @SuppressLint("InflateParams") // An overlay window has no parent.
    private val root: FrameLayout = LayoutInflater.from(ContextThemeWrapper(context, R.style.Theme_VoiceInk))
        .inflate(R.layout.mic_bubble, null) as FrameLayout
    private val expandedContainer: LinearLayout = root.findViewById(R.id.bubble_expanded)
    private val card: View = root.findViewById(R.id.bubble_card)
    private val status: TextView = root.findViewById(R.id.bubble_status)
    private val discard: Button = root.findViewById(R.id.bubble_discard)
    private val copy: Button = root.findViewById(R.id.bubble_copy)
    private val action: Button = root.findViewById(R.id.bubble_action)
    private val mic: ImageButton = root.findViewById(R.id.bubble_mic)
    private val progress: ProgressBar = root.findViewById(R.id.bubble_progress)
    private val handle: FrameLayout = root.findViewById(R.id.bubble_handle)
    private val handleTab: View = root.findViewById(R.id.bubble_handle_tab)

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
    private var glide: ValueAnimator? = null
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop

    /** A touch on the mic that started at raw ([x], [y]) with the window at ([windowX], [windowY]). */
    private class Drag(val x: Float, val y: Float, val windowX: Int, val windowY: Int) {
        var moving = false
    }

    init {
        allowDragging()
        mic.setOnClickListener { flow.onMicTapped() }
        action.setOnClickListener { flow.onActionTapped() }
        copy.setOnClickListener { flow.copyKeptText() }
        discard.setOnClickListener { flow.discard() }
        handle.setOnClickListener { expandFromHandle() }
    }

    /** Shows the bubble docked above a keyboard whose top edge is at [keyboardTop], clear of [field]. */
    fun show(keyboardTop: Int, field: Box) {
        this.keyboardTop = keyboardTop
        this.field = field
        idleCollapse.onShow(settings.idleCollapse, flow.state, SystemClock.uptimeMillis())
        render()
    }

    fun hide() {
        handler.removeCallbacks(collapseTimer)
        idleCollapse.onHide()
        field = null
        drag = null
        glide?.cancel()
        root.animate().cancel()
        if (attached) {
            windowManager.removeViewImmediate(root)
            attached = false
        }
    }

    fun render() {
        val field = field ?: return
        val state = flow.state
        val now = SystemClock.uptimeMillis()
        idleCollapse.sync(settings.idleCollapse, state, now)
        scheduleCollapse(now)

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

        val copyAvailable = CopyFallback.isAvailable(state)
        card.visibility = if (state == DictationState.Idle) View.GONE else View.VISIBLE
        status.text = DictationMessages.status(context, state, flow.macName, copyAvailable = copyAvailable)
        discard.visibility = if (state is DictationState.Kept) View.VISIBLE else View.GONE
        copy.visibility = if (copyAvailable) View.VISIBLE else View.GONE
        val label = DictationMessages.action(state) ?: if (state is DictationState.Kept) R.string.action_retry else null
        if (label != null) {
            action.setText(label)
            action.visibility = View.VISIBLE
        } else {
            action.visibility = View.GONE
        }

        val collapsed = idleCollapse.collapsed
        expandedContainer.visibility = if (collapsed) View.GONE else View.VISIBLE
        handle.visibility = if (collapsed) View.VISIBLE else View.GONE

        place(field, collapsed)
    }

    private fun expandFromHandle() {
        idleCollapse.onExpand(SystemClock.uptimeMillis())
        render()
    }

    private fun onCollapseTimer() {
        val now = SystemClock.uptimeMillis()
        if (idleCollapse.onTimeout(now)) {
            render()
        } else {
            scheduleCollapse(now)
        }
    }

    private fun scheduleCollapse(now: Long) {
        handler.removeCallbacks(collapseTimer)
        val delay = idleCollapse.remainingDelayMs(now) ?: return
        handler.postDelayed(collapseTimer, delay)
    }

    @SuppressLint("RtlHardcoded") // Collapsed handle aligns to the physical left/right screen edge.
    private fun place(field: Box, collapsed: Boolean) {
        // The finger holds the bubble; it lands where it is dropped.
        if (drag?.moving == true) return
        val rtl = context.resources.configuration.layoutDirection == View.LAYOUT_DIRECTION_RTL
        val unspecified = View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
        val area = area()
        val margin = margin()

        expandedContainer.measure(unspecified, unspecified)
        val expandedBox = BubblePlacement.place(
            area = area,
            position = settings.position,
            field = field,
            width = expandedContainer.measuredWidth,
            height = expandedContainer.measuredHeight,
            margin = margin,
            rtl = rtl,
        )

        if (!collapsed) {
            // The card lines up with the mic on whichever side the bubble sits.
            val onEndSide = (expandedBox.left + expandedBox.right) / 2 > (area.left + area.right) / 2 != rtl
            expandedContainer.gravity = if (onEndSide) Gravity.END else Gravity.START
            move(expandedBox)
            return
        }

        root.measure(unspecified, unspecified)
        val docked = BubblePlacement.dockCollapsed(
            area = area,
            expanded = expandedBox,
            handleWidth = root.measuredWidth,
            handleHeight = root.measuredHeight,
            margin = margin,
            rtl = rtl,
        )
        val tabParams = handleTab.layoutParams as FrameLayout.LayoutParams
        val desiredGravity = when (docked.edge) {
            ScreenEdge.LEFT -> Gravity.LEFT or Gravity.CENTER_VERTICAL
            ScreenEdge.RIGHT -> Gravity.RIGHT or Gravity.CENTER_VERTICAL
        }
        if (tabParams.gravity != desiredGravity) {
            tabParams.gravity = desiredGravity
            handleTab.layoutParams = tabParams
        }
        handleTab.setBackgroundResource(
            when (docked.edge) {
                ScreenEdge.LEFT -> R.drawable.bubble_handle_left_background
                ScreenEdge.RIGHT -> R.drawable.bubble_handle_right_background
            },
        )
        move(docked.box)
    }

    // Taps, including accessibility clicks, still reach the mic's own performClick.
    @SuppressLint("ClickableViewAccessibility")
    private fun allowDragging() = mic.setOnTouchListener(::onMicTouch)

    /** Taps fall through to the mic's click listener; a move past the touch slop drags the bubble instead. */
    private fun onMicTouch(view: View, event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                drag = Drag(event.rawX, event.rawY, params.x, params.y)
                idleCollapse.onTouchStarted()
                scheduleCollapse(SystemClock.uptimeMillis())
            }
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
                val now = SystemClock.uptimeMillis()
                idleCollapse.onTouchEnded(now)
                scheduleCollapse(now)
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

    /** Fades the bubble in where it belongs, glides it to a new place, and follows the finger exactly. */
    private fun move(box: Box) {
        glide?.cancel()
        if (!attached) {
            params.x = box.left
            params.y = box.top
            root.alpha = 0f
            windowManager.addView(root, params)
            attached = true
            root.animate().alpha(1f).setDuration(FADE_MS).start()
            return
        }
        val fromX = params.x
        val fromY = params.y
        if (drag?.moving == true || (fromX == box.left && fromY == box.top)) {
            params.x = box.left
            params.y = box.top
            windowManager.updateViewLayout(root, params)
            return
        }
        glide = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = GLIDE_MS
            interpolator = DecelerateInterpolator()
            addUpdateListener {
                if (!attached) return@addUpdateListener
                params.x = fromX + ((box.left - fromX) * it.animatedFraction).toInt()
                params.y = fromY + ((box.top - fromY) * it.animatedFraction).toInt()
                windowManager.updateViewLayout(root, params)
            }
            start()
        }
    }

    private companion object {
        const val MARGIN_DP = 8
        const val FADE_MS = 120L
        const val GLIDE_MS = 160L
    }
}
