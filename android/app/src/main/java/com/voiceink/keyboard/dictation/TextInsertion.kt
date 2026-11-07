package com.voiceink.keyboard.dictation

/** How dictated text joins what is already in a field. */
internal object TextInsertion {
    /** A space when the text before the cursor ends in a non-space, so words do not run together. */
    fun separator(before: CharSequence?): String =
        if (!before.isNullOrEmpty() && !before.last().isWhitespace()) " " else ""

    data class Edit(val text: String, val cursor: Int)

    /**
     * The field's new content when [text] replaces the selection of [existing] (or goes at the
     * cursor when the selection is empty, or at the end when the selection is unknown), and where
     * the cursor goes afterwards: just after the inserted text.
     */
    fun insert(existing: String, selectionStart: Int, selectionEnd: Int, text: String): Edit {
        val known = selectionStart in 0..existing.length && selectionEnd in 0..existing.length
        val start = if (known) minOf(selectionStart, selectionEnd) else existing.length
        val end = if (known) maxOf(selectionStart, selectionEnd) else existing.length
        val before = existing.substring(0, start)
        val inserted = separator(before) + text
        return Edit(before + inserted + existing.substring(end), start + inserted.length)
    }
}
