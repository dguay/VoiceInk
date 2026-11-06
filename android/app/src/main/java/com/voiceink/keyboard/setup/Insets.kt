package com.voiceink.keyboard.setup

import android.graphics.Rect
import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.widget.ScrollView

/** Keeps content clear of the status, navigation and IME bars under edge-to-edge. */
internal fun applySystemBarInsets(view: View) {
    val base = intArrayOf(view.paddingLeft, view.paddingTop, view.paddingRight, view.paddingBottom)
    view.setOnApplyWindowInsetsListener { v, insets ->
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout() or WindowInsets.Type.ime())
            v.setPadding(base[0] + bars.left, base[1] + bars.top, base[2] + bars.right, base[3] + bars.bottom)
            // Edge-to-edge windows are not resized for the keyboard: keep the focused field visible.
            if (v is ScrollView) v.post { v.revealFocusedChild() }
        } else {
            // Android 10 is not edge-to-edge here, so the system already insets the window.
            v.setPadding(base[0], base[1], base[2], base[3])
        }
        insets
    }
}

/** Scrolls just enough to show the focused field above the bottom padding (the keyboard). */
private fun ScrollView.revealFocusedChild() {
    val focused = findFocus() ?: return
    val rect = Rect()
    focused.getDrawingRect(rect)
    offsetDescendantRectToMyCoords(focused, rect)
    val margin = (16 * resources.displayMetrics.density).toInt()
    val visibleBottom = scrollY + height - paddingBottom
    if (rect.bottom + margin > visibleBottom) smoothScrollBy(0, rect.bottom + margin - visibleBottom)
}
