import AVFoundation
import Foundation
import SwiftData
import SwiftUI
import os

struct AudioRetranscriptionResult {
    let transcription: Transcription
    let enhancementFailure: String?
}

@MainActor
class AudioTranscriptionService: ObservableObject {
    @Published var isTranscribing = false {
        didSet {
            // Keeps "Restart and Update" and the installer's quit request blocked.
            guard isTranscribing != oldValue else { return }
            if isTranscribing {
                FileTranscriptionActivity.shared.begin()
            } else {
                FileTranscriptionActivity.shared.end()
            }
        }
    }
    @Published var currentError: TranscriptionError?

    private let modelContext: ModelContext
    private let enhancementService: AIEnhancementService?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioTranscriptionService")
    private let transcriber: any AudioFileTranscriber

    enum TranscriptionError: Error {
        case noAudioFile
        case transcriptionFailed
        case modelNotLoaded
        case invalidAudioFormat
    }

    init(modelContext: ModelContext, engine: VoiceInkEngine) {
        self.modelContext = modelContext
        self.enhancementService = engine.enhancementService
        self.transcriber = TranscriptionServiceRegistry(
            modelProvider: engine.whisperModelManager, modelsDirectory: engine.whisperModelManager.modelsDirectory,
            modelContext: modelContext)
    }

    convenience init(
        modelContext: ModelContext, serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        self.init(modelContext: modelContext, transcriber: serviceRegistry, enhancementService: enhancementService)
    }

    init(
        modelContext: ModelContext, transcriber: any AudioFileTranscriber,
        enhancementService: AIEnhancementService?
    ) {
        self.modelContext = modelContext
        self.enhancementService = enhancementService
        self.transcriber = transcriber
    }

    /// Transcribes `url` through the mode's dictionary, word replacements and AI cleanup.
    /// A new History entry is created with its own audio copy, unless `existing` is given:
    /// then that entry is updated in place and keeps its audio file.
    func retranscribeAudio(
        from url: URL,
        using model: any TranscriptionModel,
        mode: ModeConfig? = nil,
        updating existing: Transcription? = nil
    ) async throws -> AudioRetranscriptionResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.noAudioFile
        }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration
            let language = TranscriptionLanguageSupport.validLanguageOrFallback(
                mode?.selectedLanguage,
                for: model,
                realtimeEnabled: mode?.isRealtimeTranscriptionEnabled
            )
            let allowedAutoDetectLanguages = AutoDetectLanguageScope.effectiveAllowedLanguages(
                selectedLanguage: language,
                configuredAllowedLanguages: mode?.allowedAutoDetectLanguages,
                for: model,
                realtimeEnabled: mode?.isRealtimeTranscriptionEnabled
            )
            let vocabulary = CustomVocabularyService.shared.loadSavedVocabulary(from: modelContext)
            let requestContext = TranscriptionRequestContext(
                language: language,
                prompt: model.provider == .whisper ? WhisperPrompt.resolvedPrompt(for: language) : nil,
                vocabulary: vocabulary,
                allowedAutoDetectLanguages: allowedAutoDetectLanguages,
                zoomTextPolishingEnabled: mode?.zoomTextPolishingEnabled ?? false
            )
            let modeName = (mode?.isEnabled == true) ? mode?.name : nil
            let modeEmoji = (mode?.isEnabled == true) ? mode?.icon.value : nil

            let transcriptionStart = Date()
            var text = try await transcriber.transcribe(audioURL: url, model: model, context: requestContext)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
            text = TranscriptionOutputFilter.filter(text, language: language)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = try await vocabulary.correctTranscription(text)
            let formattingConfiguration = ModeRuntimeResolver.transcriptionFormattingConfiguration(mode: mode)

            if formattingConfiguration.isTextFormattingEnabled {
                text = ParagraphFormatter.format(text)
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)

            let audioAsset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))

            var output = RetranscriptionOutput(
                text: text,
                duration: duration,
                transcriptionModelName: model.displayName,
                transcriptionDuration: transcriptionDuration,
                modeName: modeName,
                modeEmoji: modeEmoji
            )
            var enhancementFailure: String?

            let enhancementConfiguration =
                enhancementService
                .flatMap { service in
                    service.getAIService().map { aiService in
                        ModeRuntimeResolver.currentEnhancementConfiguration(
                            mode: mode,
                            enhancementService: service,
                            aiService: aiService
                        )
                    }
                }

            // Apply AI enhancement if enabled
            if let enhancementService = enhancementService,
                let enhancementConfiguration,
                enhancementConfiguration.isEnabled,
                enhancementService.isConfigured(for: enhancementConfiguration)
            {
                output.isEnhancementAttempted = true
                output.aiEnhancementModelName =
                    enhancementConfiguration.modelName ?? enhancementConfiguration.provider?.defaultModel
                do {
                    let enhancementResult = try await enhancementService.enhance(
                        text,
                        configuration: enhancementConfiguration,
                        vocabulary: vocabulary
                    )
                    output.enhancedText = enhancementResult.text
                    output.promptName = enhancementResult.promptName ?? enhancementConfiguration.prompt?.title
                    output.enhancementDuration = enhancementResult.duration
                    output.aiRequestSystemMessage = enhancementResult.systemMessage
                    output.aiRequestUserMessage = enhancementResult.userMessage
                } catch {
                    let failureDescription = EnhancementFailureFormatter.description(for: error)
                    output.enhancedText = EnhancementFailureFormatter.message(description: failureDescription)
                    output.promptName = enhancementConfiguration.prompt?.title
                    enhancementFailure = failureDescription
                }
            }

            let transcription: Transcription
            if let existing {
                output.apply(to: existing)
                transcription = existing
            } else {
                transcription = try makeTranscription(from: output, copyingAudioFrom: url)
                modelContext.insert(transcription)
            }

            do {
                try modelContext.save()
                if existing == nil, output.isEnhancementAttempted {
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
                }
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
            } catch {
                logger.error("❌ Failed to save transcription: \(error, privacy: .public)")
            }

            return AudioRetranscriptionResult(
                transcription: transcription,
                enhancementFailure: enhancementFailure
            )
        } catch {
            logger.error("❌ Transcription failed: \(error, privacy: .public)")
            currentError = .transcriptionFailed
            throw error
        }
    }

    private func makeTranscription(
        from output: RetranscriptionOutput,
        copyingAudioFrom url: URL
    ) throws -> Transcription {
        let recordingsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("Recordings")
        let permanentURL = recordingsDirectory.appendingPathComponent("retranscribed_\(UUID().uuidString).wav")

        do {
            try FileManager.default.copyItem(at: url, to: permanentURL)
        } catch {
            logger.error("❌ Failed to create permanent copy of audio: \(error, privacy: .public)")
            throw error
        }

        return Transcription(
            text: output.text,
            duration: output.duration,
            enhancedText: output.enhancedText,
            audioFileURL: permanentURL.absoluteString,
            transcriptionModelName: output.transcriptionModelName,
            aiEnhancementModelName: output.aiEnhancementModelName,
            promptName: output.promptName,
            transcriptionDuration: output.transcriptionDuration,
            enhancementDuration: output.enhancementDuration,
            aiRequestSystemMessage: output.aiRequestSystemMessage,
            aiRequestUserMessage: output.aiRequestUserMessage,
            modeName: output.modeName,
            modeEmoji: output.modeEmoji
        )
    }
}

private struct RetranscriptionOutput {
    let text: String
    let duration: TimeInterval
    let transcriptionModelName: String
    let transcriptionDuration: TimeInterval
    let modeName: String?
    let modeEmoji: String?
    var isEnhancementAttempted = false
    var enhancedText: String?
    var aiEnhancementModelName: String?
    var promptName: String?
    var enhancementDuration: TimeInterval?
    var aiRequestSystemMessage: String?
    var aiRequestUserMessage: String?

    func apply(to transcription: Transcription) {
        transcription.text = text
        transcription.enhancedText = enhancedText
        transcription.duration = duration
        transcription.transcriptionModelName = transcriptionModelName
        transcription.aiEnhancementModelName = aiEnhancementModelName
        transcription.promptName = promptName
        transcription.transcriptionDuration = transcriptionDuration
        transcription.enhancementDuration = enhancementDuration
        transcription.aiRequestSystemMessage = aiRequestSystemMessage
        transcription.aiRequestUserMessage = aiRequestUserMessage
        transcription.modeName = modeName
        transcription.modeEmoji = modeEmoji
        transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue
    }
}
