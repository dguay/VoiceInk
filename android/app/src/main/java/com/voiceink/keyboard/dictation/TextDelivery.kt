package com.voiceink.keyboard.dictation

/**
 * Decides whether a transcription may be typed, so text only reaches the field it was dictated
 * for and the recording is deleted only once its text is really in that field.
 *
 * Every new input session (another field, another app, the keyboard hidden) invalidates the
 * tickets handed out before it.
 */
class TextDelivery {
    /** Identifies the input session a request started in. */
    @JvmInline value class Ticket internal constructor(internal val session: Long)

    enum class Outcome {
        /** The text was committed and the recording deleted. */
        INSERTED,

        /** The Mac heard nothing; the recording was deleted. */
        EMPTY,

        /** The field changed while the Mac was working; the recording is kept for a retry. */
        FIELD_CHANGED,

        /** The editor rejected the text; the recording is kept for a retry. */
        REJECTED,
    }

    private var session = 0L
    private var open = false

    /**
     * A field gained the keyboard. [sameField] is true when the editor only restarted its input
     * while it kept the keyboard; that does not invalidate pending tickets.
     */
    fun startSession(sameField: Boolean = false) {
        if (sameField && open) return
        session++
        open = true
    }

    /** The field lost the keyboard; pending tickets can no longer insert. */
    fun endSession() {
        session++
        open = false
    }

    fun ticket(): Ticket = Ticket(session)

    /**
     * Commits [text] through [commit] when [ticket] still matches the open session. [discard]
     * deletes the kept recording and runs only for [Outcome.INSERTED] and [Outcome.EMPTY].
     */
    fun deliver(ticket: Ticket, text: String, commit: (String) -> Boolean, discard: () -> Unit): Outcome {
        if (!open || ticket.session != session) return Outcome.FIELD_CHANGED
        if (text.isBlank()) {
            discard()
            return Outcome.EMPTY
        }
        if (!commit(text)) return Outcome.REJECTED
        discard()
        return Outcome.INSERTED
    }
}
