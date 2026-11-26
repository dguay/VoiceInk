import AVFoundation
import Foundation
import SwiftData
import os

/// Transcribes one audio file with a mode's model and returns the raw text.
@MainActor
protocol AudioFileTranscriber: AnyObject {
    /// Loads `model` ahead of `transcribe`, so the load is timed on its own. Optional.
    func prepare(model: any TranscriptionModel) async throws
    func transcribe(
        audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> String
    func cleanup() async
}

extension AudioFileTranscriber {
    func prepare(model: any TranscriptionModel) async throws {}
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
    /// How long each step took.
    var timings = AudioFileTranscriptionTimings()
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
    /// Set for phone dictation only; see `WarmAudioFileTranscriber` for why it is a separate instance.
    private let warmTranscriber: WarmAudioFileTranscriber?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioFileTranscriptionPipeline")
    private static let phoneLogger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "PhoneDictation")

    /// - Parameter keepsTranscriberWarm: keep one transcriber, and its loaded model, between runs
    ///   (phone dictation). When false, every file gets a fresh transcriber that is cleaned up
    ///   afterwards (Audio Import).
    convenience init(modelContext: ModelContext, engine: VoiceInkEngine, keepsTranscriberWarm: Bool = false) {
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
            ),
            keepsTranscriberWarm: keepsTranscriberWarm
        )
    }

    init(modelContext: ModelContext, dependencies: Dependencies, keepsTranscriberWarm: Bool = false) {
        self.modelContext = modelContext
        self.dependencies = dependencies
        self.warmTranscriber =
            keepsTranscriberWarm ? WarmAudioFileTranscriber(makeTranscriber: dependencies.makeTranscriber) : nil
    }

    /// Frees the warm transcriber and its model, if any. A run that is using it keeps it until it
    /// finishes; the next run loads the model again.
    func releaseWarmTranscriber() async {
        await warmTranscriber?.release()
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
        options: AudioFileTranscriptionOptions = AudioFileTranscriptionOptions(),
        onPhase: (Phase) -> Void = { _ in }
    ) async throws -> AudioFileTranscriptionResult {
        let startedAt = ContinuousClock.now
        if let warmTranscriber {
            // Phone dictation: reuse the warm transcriber, which stays loaded after the run.
            var lease: WarmAudioFileTranscriber.Lease?
            do {
                let transcription = try await run(
                    audioURL: audioURL, mode: mode, source: source, options: options, startedAt: startedAt,
                    acquireTranscriber: { model in
                        let checkedOut = await warmTranscriber.checkOut(for: model)
                        lease = checkedOut
                        return (checkedOut.transcriber, checkedOut.isReused)
                    },
                    onPhase: onPhase)
                if let lease { await warmTranscriber.checkIn(lease) }
                return transcription
            } catch {
                if let lease { await warmTranscriber.checkIn(lease) }
                throw error
            }
        }

        let transcriber = dependencies.makeTranscriber()
        do {
            let transcription = try await run(
                audioURL: audioURL, mode: mode, source: source, options: options, startedAt: startedAt,
                acquireTranscriber: { _ in (transcriber, false) }, onPhase: onPhase)
            await transcriber.cleanup()
            return transcription
        } catch {
            await transcriber.cleanup()
            throw error
        }
    }

    /// `acquireTranscriber` returns the transcriber for the resolved model and whether it was
    /// reused from an earlier run; it is called once the audio is converted.
    private func run(
        audioURL: URL,
        mode: ModeConfig,
        source: TranscriptionSource?,
        options: AudioFileTranscriptionOptions,
        startedAt: ContinuousClock.Instant,
        acquireTranscriber: (any TranscriptionModel) async -> (any AudioFileTranscriber, Bool),
        onPhase: (Phase) -> Void
    ) async throws -> AudioFileTranscriptionResult {
        guard let transcriptionConfiguration = dependencies.resolveConfiguration(mode) else {
            throw TranscriptionError.noModelSelected
        }
        let currentModel = transcriptionConfiguration.model
        var timings = AudioFileTranscriptionTimings()

        onPhase(.loading)
        try Task.checkCancellation()

        onPhase(.processingAudio)
        let conversionStart = ContinuousClock.now
        let samples = try await audioProcessor.processAudioToSamples(audioURL)
        try Task.checkCancellation()

        let audioAsset = AVURLAsset(url: audioURL)
        let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))

        let recordingsDirectory = dependencies.recordingsDirectory
        let fileName = "transcribed_\(UUID().uuidString).wav"
        let permanentURL = recordingsDirectory.appendingPathComponent(fileName)

        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        try audioProcessor.saveSamplesAsWav(samples: samples, to: permanentURL)
        timings.audioConversion = conversionStart.duration(to: .now).timeInterval
        try Task.checkCancellation()

        onPhase(.transcribing)
        let loadStart = ContinuousClock.now
        let (transcriber, isReused) = await acquireTranscriber(currentModel)
        timings.reusedWarmTranscriber = isReused
        do {
            try await transcriber.prepare(model: currentModel)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // `transcribe` loads lazily and reports the failure as it always did.
            logger.notice("Model preload failed, transcribing anyway: \(error, privacy: .public)")
        }
        timings.modelLoad = loadStart.duration(to: .now).timeInterval
        try Task.checkCancellation()

        let vocabulary = CustomVocabularyService.shared.loadSavedVocabulary(from: modelContext)
        let transcriptionStart = ContinuousClock.now
        var text = try await transcriber.transcribe(
            audioURL: permanentURL,
            model: currentModel,
            context: transcriptionConfiguration.requestContext.withVocabulary(vocabulary)
        )
        timings.transcription = transcriptionStart.duration(to: .now).timeInterval
        // History keeps counting the model load, as it did when the load happened inside transcribe.
        let transcriptionDuration = timings.modelLoad + timings.transcription
        text = TranscriptionOutputFilter.filter(text, language: transcriptionConfiguration.language)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = try await vocabulary.correctTranscription(text)

        let modeMetadata = transcriptionConfiguration.metadata
        let formattingConfiguration = ModeRuntimeResolver.transcriptionFormattingConfiguration(mode: mode)

        if formattingConfiguration.isTextFormattingEnabled, !options.skipsAIEnhancementAndFormatting {
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

        if !options.skipsAIEnhancementAndFormatting,
            let enhancementService = dependencies.enhancementService,
            let enhancementConfiguration,
            enhancementConfiguration.isEnabled,
            enhancementService.isConfigured(for: enhancementConfiguration)
        {
            onPhase(.enhancing)
            let enhancementStart = ContinuousClock.now
            defer { timings.enhancement = enhancementStart.duration(to: .now).timeInterval }
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

        transcription.sourceApp = options.sourceApp
        modelContext.insert(transcription)
        try modelContext.save()
        NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
        NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)

        timings.total = startedAt.duration(to: .now).timeInterval
        logTimings(timings, source: source)

        return AudioFileTranscriptionResult(
            transcription: transcription,
            finalText: finalText,
            enhancementFailure: enhancementFailure,
            timings: timings
        )
    }

    /// Logs step durations only: never the transcript, the dictated text or the audio.
    private func logTimings(_ timings: AudioFileTranscriptionTimings, source: TranscriptionSource?) {
        if source == .phone {
            Self.phoneLogger.notice("Phone dictation timings: \(timings.logDescription, privacy: .public)")
        } else {
            logger.debug("Audio file timings: \(timings.logDescription, privacy: .public)")
        }
    }
}
