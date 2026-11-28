import Foundation

struct TranscriptionRequestContext {
    let language: String?
    let prompt: String?
    var vocabulary: RecordingVocabulary? = nil
    var allowedAutoDetectLanguages: [String] = []
    /// The mode's Zoom Polishing choice. Read by the Zoom Scribe batch and streaming paths only.
    var zoomTextPolishingEnabled: Bool = false

    static var currentDefaults: TranscriptionRequestContext {
        let language = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "auto"
        return TranscriptionRequestContext(
            language: language,
            prompt: WhisperPrompt.resolvedPrompt(for: language)
        )
    }

    func withVocabulary(_ vocabulary: RecordingVocabulary) -> TranscriptionRequestContext {
        var context = self
        context.vocabulary = vocabulary
        return context
    }

    func scoped(to model: any TranscriptionModel) -> TranscriptionRequestContext {
        let reconciledAllowed = AutoDetectLanguageScope.effectiveAllowedLanguages(
            selectedLanguage: language,
            configuredAllowedLanguages: allowedAutoDetectLanguages,
            for: model
        )
        guard model.provider == .whisper else {
            return TranscriptionRequestContext(
                language: language,
                prompt: nil,
                vocabulary: vocabulary,
                allowedAutoDetectLanguages: reconciledAllowed,
                zoomTextPolishingEnabled: zoomTextPolishingEnabled
            )
        }

        return TranscriptionRequestContext(
            language: language,
            prompt: prompt,
            vocabulary: vocabulary,
            allowedAutoDetectLanguages: reconciledAllowed
        )
    }
}

/// A protocol defining the interface for a transcription service.
/// This allows for a unified way to handle both local and cloud-based transcription models.
protocol TranscriptionService {
    /// Transcribes the audio from a given file URL.
    ///
    /// - Parameters:
    ///   - audioURL: The URL of the audio file to transcribe.
    ///   - model: The `TranscriptionModel` to use for transcription. This provides context about the provider (local, OpenAI, etc.).
    /// - Returns: The transcribed text as a `String`.
    /// - Throws: An error if the transcription fails.
    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
}

extension TranscriptionService {
    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        let context = TranscriptionRequestContext.currentDefaults.scoped(to: model)
        return try await transcribe(audioURL: audioURL, model: model, context: context)
    }
}
