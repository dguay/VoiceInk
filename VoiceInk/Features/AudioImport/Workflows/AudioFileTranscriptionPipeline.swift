import AVFoundation
import Foundation
import SwiftData

/// Transcribes one audio file with a mode's model and returns the raw text.
@MainActor
protocol AudioFileTranscriber: AnyObject {
    func transcribe(
        audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> String
    func cleanup() async
}

extension TranscriptionServiceRegistry: AudioFileTranscriber {}

/// One audio file in, final text out: the path shared by Audio Import and phone dictation.
///
/// It resolves the mode's transcription model, converts the audio to a permanent 16 kHz WAV in
/// Recordings, transcribes it, applies the output filter, dictionary, formatting, word replacements
/// and the mode's AI enhancement, then saves the result to History.
struct AudioFileTranscriptionResult {
    /// The History entry that was saved.
    let transcription: Transcription
    /// The finished text: the AI-enhanced text when enhancement succeeded, otherwise the cleaned text.
    let finalText: String
    /// Why AI enhancement failed, when it was attempted and failed.
    let enhancementFailure: String?
}

@MainActor
final class AudioFileTranscriptionPipeline {
    enum Phase: Equatable {
        case loading
        case processingAudio
        case transcribing
        case enhancing
    }

    struct Dependencies {
        var resolveConfiguration: @MainActor (ModeConfig) -> TranscriptionRuntimeConfiguration?
        var makeTranscriber: @MainActor () -> any AudioFileTranscriber
        var enhancementService: AIEnhancementService?
        var recordingsDirectory: URL
    }

    static var defaultRecordingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("Recordings")
    }

    private let modelContext: ModelContext
    private let dependencies: Dependencies
    private let audioProcessor = AudioProcessor()

    convenience init(modelContext: ModelContext, engine: VoiceInkEngine) {
        self.init(
            modelContext: modelContext,
            dependencies: Dependencies(
                resolveConfiguration: { mode in
                    ModeRuntimeResolver.transcriptionConfiguration(
                        mode: mode,
                        transcriptionModelManager: engine.transcriptionModelManager
                    )
                },
                makeTranscriber: {
                    // A fresh registry per file, cleaned up afterwards, as Audio Import always did.
                    TranscriptionServiceRegistry(
                        modelProvider: engine.whisperModelManager,
                        modelsDirectory: engine.whisperModelManager.modelsDirectory,
                        modelContext: modelContext
                    )
                },
                enhancementService: engine.enhancementService,
                recordingsDirectory: Self.defaultRecordingsDirectory
            )
        )
    }

    init(modelContext: ModelContext, dependencies: Dependencies) {
        self.modelContext = modelContext
        self.dependencies = dependencies
    }

    /// Whether `mode` currently resolves to a usable transcription model.
    func isReady(mode: ModeConfig?) -> Bool {
        guard let mode else { return false }
        return dependencies.resolveConfiguration(mode) != nil
    }

    /// Runs the full pipeline for `audioURL` and returns the saved History entry and final text.
    ///
    /// Throws `TranscriptionError.noModelSelected` before any phase when the mode has no usable
    /// model, and `CancellationError` when the surrounding task is cancelled.
    func transcribe(
        audioURL: URL,
        mode: ModeConfig,
        source: TranscriptionSource? = nil,
        onPhase: (Phase) -> Void = { _ in }
    ) async throws -> AudioFileTranscriptionResult {
        let transcriber = dependencies.makeTranscriber()
        do {
            let transcription = try await run(
                audioURL: audioURL, mode: mode, source: source, transcriber: transcriber, onPhase: onPhase)
            await transcriber.cleanup()
            return transcription
        } catch {
            await transcriber.cleanup()
            throw error
        }
    }

    private func run(
        audioURL: URL,
        mode: ModeConfig,
        source: TranscriptionSource?,
        transcriber: any AudioFileTranscriber,
        onPhase: (Phase) -> Void
    ) async throws -> AudioFileTranscriptionResult {
        guard let transcriptionConfiguration = dependencies.resolveConfiguration(mode) else {
            throw TranscriptionError.noModelSelected
        }
        let currentModel = transcriptionConfiguration.model

        onPhase(.loading)
        try Task.checkCancellation()

        onPhase(.processingAudio)
        let samples = try await audioProcessor.processAudioToSamples(audioURL)
        try Task.checkCancellation()

        let audioAsset = AVURLAsset(url: audioURL)
        let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))

        let recordingsDirectory = dependencies.recordingsDirectory
        let fileName = "transcribed_\(UUID().uuidString).wav"
        let permanentURL = recordingsDirectory.appendingPathComponent(fileName)

        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        try audioProcessor.saveSamplesAsWav(samples: samples, to: permanentURL)
        try Task.checkCancellation()

        onPhase(.transcribing)
        let vocabulary = CustomVocabularyService.shared.loadSavedVocabulary(from: modelContext)
        let transcriptionStart = Date()
        var text = try await transcriber.transcribe(
            audioURL: permanentURL,
            model: currentModel,
            context: transcriptionConfiguration.requestContext.withVocabulary(vocabulary)
        )
        let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
        text = TranscriptionOutputFilter.filter(text, language: transcriptionConfiguration.language)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = try await vocabulary.correctTranscription(text)

        let modeMetadata = transcriptionConfiguration.metadata
        let formattingConfiguration = ModeRuntimeResolver.transcriptionFormattingConfiguration(mode: mode)

        if formattingConfiguration.isTextFormattingEnabled {
            text = ParagraphFormatter.format(text)
        }

        text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
        let cleanedText = text
        try Task.checkCancellation()

        var transcription: Transcription
        var finalText = cleanedText
        var enhancementFailure: String?

        let enhancementConfiguration = dependencies.enhancementService
            .flatMap { enhancementService in
                enhancementService.getAIService().map { aiService in
                    ModeRuntimeResolver.currentEnhancementConfiguration(
                        mode: mode,
                        enhancementService: enhancementService,
                        aiService: aiService
                    )
                }
            }

        if let enhancementService = dependencies.enhancementService,
            let enhancementConfiguration,
            enhancementConfiguration.isEnabled,
            enhancementService.isConfigured(for: enhancementConfiguration)
        {
            onPhase(.enhancing)
            do {
                let enhancementResult = try await enhancementService.enhance(
                    text,
                    configuration: enhancementConfiguration,
                    vocabulary: vocabulary
                )
                transcription = Transcription(
                    text: cleanedText,
                    duration: duration,
                    enhancedText: enhancementResult.text,
                    audioFileURL: permanentURL.absoluteString,
                    transcriptionModelName: currentModel.displayName,
                    aiEnhancementModelName: enhancementConfiguration.modelName
                        ?? enhancementConfiguration.provider?.defaultModel,
                    promptName: enhancementResult.promptName
                        ?? enhancementConfiguration.prompt?.title,
                    transcriptionDuration: transcriptionDuration,
                    enhancementDuration: enhancementResult.duration,
                    aiRequestSystemMessage: enhancementResult.systemMessage,
                    aiRequestUserMessage: enhancementResult.userMessage,
                    modeName: modeMetadata.name,
                    modeEmoji: modeMetadata.emoji,
                    source: source
                )
                finalText = enhancementResult.text
            } catch {
                let failureDescription = EnhancementFailureFormatter.description(for: error)
                let failureMessage = EnhancementFailureFormatter.message(description: failureDescription)
                enhancementFailure = failureDescription
                transcription = Transcription(
                    text: cleanedText,
                    duration: duration,
                    enhancedText: failureMessage,
                    audioFileURL: permanentURL.absoluteString,
                    transcriptionModelName: currentModel.displayName,
                    aiEnhancementModelName: enhancementConfiguration.modelName
                        ?? enhancementConfiguration.provider?.defaultModel,
                    promptName: enhancementConfiguration.prompt?.title,
                    transcriptionDuration: transcriptionDuration,
                    modeName: modeMetadata.name,
                    modeEmoji: modeMetadata.emoji,
                    source: source
                )
            }
        } else {
            transcription = Transcription(
                text: cleanedText,
                duration: duration,
                audioFileURL: permanentURL.absoluteString,
                transcriptionModelName: currentModel.displayName,
                promptName: nil,
                transcriptionDuration: transcriptionDuration,
                modeName: modeMetadata.name,
                modeEmoji: modeMetadata.emoji,
                source: source
            )
        }

        modelContext.insert(transcription)
        try modelContext.save()
        NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
        NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)

        return AudioFileTranscriptionResult(
            transcription: transcription,
            finalText: finalText,
            enhancementFailure: enhancementFailure
        )
    }
}
