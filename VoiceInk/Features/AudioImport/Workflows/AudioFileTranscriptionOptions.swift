import Foundation

/// Per-request choices for `AudioFileTranscriptionPipeline.transcribe`, decided by the caller
/// rather than by changing the mode.
struct AudioFileTranscriptionOptions: Equatable {
    /// Recorded on the History entry: the Android package of the app a phone dictation was for.
    var sourceApp: String? = nil
    /// Skips paragraph formatting and AI enhancement even when the mode turns them on. The output
    /// filter, dictionary correction and word replacements still run.
    var skipsAIEnhancementAndFormatting = false
}
