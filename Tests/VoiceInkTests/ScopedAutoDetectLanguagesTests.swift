import Foundation
import SwiftData
import Testing
@testable import VoiceInk

// Issue #65: Scoped auto-detect language list (e.g. English and French only).

// MARK: - Whisper probability-distribution selection

struct WhisperAutoDetectLanguageSelectorTests {
    private let english = WhisperLanguageCandidate(languageID: 0, code: "en")
    private let french = WhisperLanguageCandidate(languageID: 3, code: "fr")

    @Test func selectsHighestProbabilityWithinAllowedSubsetEvenWhenUnlistedLanguageDominates() {
        var probabilities = [Float](repeating: 0.0, count: 100)
        probabilities[0] = 0.04 // en
        probabilities[2] = 0.88 // de (unlisted, dominant)
        probabilities[3] = 0.08 // fr

        let selected = WhisperAutoDetectLanguageSelector.selectBestLanguage(
            probabilities: probabilities,
            allowedCandidates: [english, french]
        )
        #expect(selected == french)
    }

    @Test func selectsEnglishWhenEnglishBeatsFrenchAmongAllowedSubset() {
        var probabilities = [Float](repeating: 0.0, count: 100)
        probabilities[0] = 0.14 // en
        probabilities[3] = 0.06 // fr
        probabilities[7] = 0.80 // ja (unlisted, dominant)

        let selected = WhisperAutoDetectLanguageSelector.selectBestLanguage(
            probabilities: probabilities,
            allowedCandidates: [english, french]
        )
        #expect(selected == english)
    }

    @Test func breaksExactTiesDeterministicallyByCandidateOrder() {
        var probabilities = [Float](repeating: 0.0, count: 10)
        probabilities[0] = 0.25
        probabilities[3] = 0.25

        let enFirst = WhisperAutoDetectLanguageSelector.selectBestLanguage(
            probabilities: probabilities,
            allowedCandidates: [english, french]
        )
        let frFirst = WhisperAutoDetectLanguageSelector.selectBestLanguage(
            probabilities: probabilities,
            allowedCandidates: [french, english]
        )
        #expect(enFirst == english)
        #expect(frFirst == french)
    }

    @Test func ignoresNonFiniteProbabilitiesAndNeverEscapesAllowedSubset() {
        var probabilities = [Float](repeating: 0.99, count: 10)
        probabilities[0] = .nan
        probabilities[3] = 0.01

        let selected = WhisperAutoDetectLanguageSelector.selectBestLanguage(
            probabilities: probabilities,
            allowedCandidates: [english, french]
        )
        #expect(selected == french)

        probabilities[3] = .infinity
        let fallback = WhisperAutoDetectLanguageSelector.selectBestLanguage(
            probabilities: probabilities,
            allowedCandidates: [english, french]
        )
        #expect(fallback == english)
    }

    @Test func returnsNilWhenAllowedCandidatesAreEmpty() {
        let selected = WhisperAutoDetectLanguageSelector.selectBestLanguage(
            probabilities: [0.9, 0.1],
            allowedCandidates: []
        )
        #expect(selected == nil)
    }

    @Test func singleAllowedCandidateAlwaysWins() {
        var probabilities = [Float](repeating: 0.0, count: 10)
        probabilities[0] = 0.99
        probabilities[3] = 0.001

        let selected = WhisperAutoDetectLanguageSelector.selectBestLanguage(
            probabilities: probabilities,
            allowedCandidates: [french]
        )
        #expect(selected == french)
    }
}

// MARK: - Normalization, compatibility hints, and persistence

struct ScopedAutoDetectSettingsTests {
    private var multilingualWhisper: WhisperModel {
        WhisperModel(
            name: "ggml-large-v3-turbo",
            displayName: "Large v3 Turbo",
            size: "1.5 GB",
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
            description: "Test multilingual Whisper",
            speed: 0.75,
            accuracy: 0.94,
            ramUsage: 1.8
        )
    }

    private var englishOnlyWhisper: WhisperModel {
        WhisperModel(
            name: "ggml-tiny.en",
            displayName: "Tiny (English)",
            size: "75 MB",
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: false, provider: .whisper),
            description: "Test English-only Whisper",
            speed: 0.95,
            accuracy: 0.65,
            ramUsage: 0.3
        )
    }

    private var parakeetMultilingual: FluidAudioModel {
        FluidAudioModel(
            name: "parakeet-tdt-0.6b-v3",
            displayName: "Parakeet V3",
            description: "Test Parakeet V3",
            size: "494 MB",
            speed: 0.99,
            accuracy: 0.94,
            ramUsage: 0.8,
            supportsStreaming: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .fluidAudio)
        )
    }

    private var nemotronLatin: FluidAudioModel {
        FluidAudioModel(
            name: "nemotron-latin-0.6b",
            displayName: "Nemotron Latin",
            description: "Test Nemotron",
            size: "620 MB",
            speed: 0.99,
            accuracy: 0.92,
            ramUsage: 1.2,
            supportsStreaming: true,
            supportedLanguages: LanguageDictionary.nemotronLatin
        )
    }

    private var cloudGroq: CloudModel {
        CloudModel(
            name: "whisper-large-v3-turbo",
            displayName: "Groq Whisper",
            description: "Test Cloud model",
            provider: .groq,
            isMultilingual: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper)
        )
    }

    @Test func normalizesDeduplicatesAndStripsAuto() {
        let normalized = AutoDetectLanguageScope.normalize([" en ", "auto", "AUTO", "fr", "EN", "", "   ", "fr"])
        #expect(normalized == ["en", "fr"])
        #expect(AutoDetectLanguageScope.normalizedOrNil(["auto", " "]) == nil)
    }

    @Test func reconcilesLanguageCodesAcrossRegionalAndBareSubtags() {
        #expect(AutoDetectLanguageScope.reconcile(["en", "fr"], for: nemotronLatin) == ["en-US", "fr-FR"])
        #expect(AutoDetectLanguageScope.reconcile(["en-US", "fr-CA", "xx-YY"], for: multilingualWhisper) == ["en", "fr"])
    }

    @Test func effectiveAllowedLanguagesApplyOnlyInAutoDetectMode() {
        #expect(
            AutoDetectLanguageScope.effectiveAllowedLanguages(
                selectedLanguage: "auto",
                configuredAllowedLanguages: ["en", "fr"],
                for: multilingualWhisper
            ) == ["en", "fr"]
        )
        #expect(
            AutoDetectLanguageScope.effectiveAllowedLanguages(
                selectedLanguage: "en",
                configuredAllowedLanguages: ["en", "fr"],
                for: multilingualWhisper
            ).isEmpty
        )
        #expect(
            AutoDetectLanguageScope.effectiveAllowedLanguages(
                selectedLanguage: "auto",
                configuredAllowedLanguages: [],
                for: multilingualWhisper
            ).isEmpty
        )
        #expect(
            AutoDetectLanguageScope.effectiveAllowedLanguages(
                selectedLanguage: "auto",
                configuredAllowedLanguages: ["en", "fr"],
                for: englishOnlyWhisper
            ).isEmpty
        )
    }

    @Test func compatibilitySupportAndHintsDistinguishLocalWhisperFromOtherModels() {
        #expect(AutoDetectLanguageScope.supportsNativeScopedAutoDetect(model: multilingualWhisper))
        #expect(!AutoDetectLanguageScope.supportsNativeScopedAutoDetect(model: englishOnlyWhisper))
        #expect(!AutoDetectLanguageScope.supportsNativeScopedAutoDetect(model: parakeetMultilingual))
        #expect(!AutoDetectLanguageScope.supportsNativeScopedAutoDetect(model: cloudGroq))

        let parakeetHint = AutoDetectLanguageScope.compatibilityHint(for: parakeetMultilingual, hasAllowedLanguages: true)
        #expect(parakeetHint.contains("Whisper"))
        #expect(parakeetHint.contains("Parakeet V3"))
        #expect(parakeetHint.contains("AI cleanup"))
        #expect(!parakeetHint.contains("—"))
        #expect(!parakeetHint.contains("·"))

        let cloudHint = AutoDetectLanguageScope.compatibilityHint(for: cloudGroq, hasAllowedLanguages: true)
        #expect(cloudHint.contains("Whisper"))
        #expect(cloudHint.contains("Groq Whisper"))
        #expect(cloudHint.contains("AI cleanup"))
    }

    @Test func badgeLabelFormatsEmptySmallAndLargerSubsets() {
        #expect(AutoDetectLanguageScope.badgeLabel(for: nil) == "Auto")
        #expect(AutoDetectLanguageScope.badgeLabel(for: []) == "Auto")
        #expect(AutoDetectLanguageScope.badgeLabel(for: ["en", "fr"]) == "Auto (EN, FR)")
        #expect(AutoDetectLanguageScope.badgeLabel(for: ["en", "fr", "es"]) == "Auto (3 languages)")
    }

    @Test func modeConfigPersistsAndBackupRoundTripsAllowedAutoDetectLanguages() throws {
        let legacyJSON = """
            {"id":"6B1C6B8E-1D7A-4C2E-9F55-2E3B9E1C0A11","name":"Legacy","icon":{"kind":"symbol","value":"pencil"},
            "isAIEnhancementEnabled":false,"isRealtimeTranscriptionEnabled":true,"selectedLanguage":"auto",
            "isTextFormattingEnabled":true,"useClipboardContext":false,"useSelectedTextContext":true,
            "useScreenCapture":false,"outputMode":"paste","autoSendKey":"none","isEnabled":true,"isDefault":false}
            """
        let legacyMode = try JSONDecoder().decode(ModeConfig.self, from: Data(legacyJSON.utf8))
        #expect(legacyMode.allowedAutoDetectLanguages == nil)
        let reencodedLegacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyMode)) as? [String: Any]
        #expect(reencodedLegacy?["allowedAutoDetectLanguages"] == nil)

        var bilingualMode = ModeConfig(
            name: "Bilingual",
            isAIEnhancementEnabled: true,
            selectedTranscriptionModelName: "ggml-large-v3-turbo",
            selectedLanguage: "auto",
            allowedAutoDetectLanguages: ["en", "fr", "auto", "EN"]
        )
        #expect(bilingualMode.allowedAutoDetectLanguages == ["en", "fr"])

        let backup = BackupFile(
            version: "1.0",
            customPrompts: [],
            modeConfigs: [bilingualMode, legacyMode],
            modeShortcuts: nil,
            vocabularyWords: nil,
            wordReplacements: nil,
            generalSettings: nil,
            customEmojis: nil,
            customCloudModels: nil
        )
        let restored = try JSONDecoder().decode(BackupFile.self, from: JSONEncoder().encode(backup))
        #expect(restored.modeConfigs.first?.allowedAutoDetectLanguages == ["en", "fr"])
        #expect(restored.modeConfigs.last?.allowedAutoDetectLanguages == nil)

        // Clearing the allowed list removes the field and restores unconstrained Auto-detect.
        bilingualMode.allowedAutoDetectLanguages = []
        let cleared = try JSONDecoder().decode(ModeConfig.self, from: JSONEncoder().encode(bilingualMode))
        #expect(cleared.allowedAutoDetectLanguages == nil)
    }

    @MainActor
    @Test func runtimeConfigurationPropagatesAndClearsAllowedLanguagesCorrectly() throws {
        let bilingualMode = ModeConfig(
            name: "Bilingual",
            isAIEnhancementEnabled: true,
            selectedTranscriptionModelName: multilingualWhisper.selectionKey,
            selectedLanguage: "auto",
            allowedAutoDetectLanguages: ["en", "fr"]
        )
        let resolved = try #require(
            ModeRuntimeResolver.transcriptionConfiguration(
                from: .available(mode: bilingualMode, model: multilingualWhisper)
            )
        )
        #expect(resolved.language == "auto")
        #expect(resolved.allowedAutoDetectLanguages == ["en", "fr"])
        #expect(resolved.requestContext.allowedAutoDetectLanguages == ["en", "fr"])

        let singleLanguageMode = ModeConfig(
            name: "French Only",
            isAIEnhancementEnabled: true,
            selectedTranscriptionModelName: multilingualWhisper.selectionKey,
            selectedLanguage: "fr",
            allowedAutoDetectLanguages: ["en", "fr"]
        )
        let resolvedSingle = try #require(
            ModeRuntimeResolver.transcriptionConfiguration(
                from: .available(mode: singleLanguageMode, model: multilingualWhisper)
            )
        )
        #expect(resolvedSingle.language == "fr")
        #expect(resolvedSingle.allowedAutoDetectLanguages.isEmpty)
        #expect(resolvedSingle.requestContext.allowedAutoDetectLanguages.isEmpty)
    }

    @Test func modeConfigDraftPreservesReconcilesAndClearsAllowedLanguages() {
        let mode = ModeConfig(
            name: "Bilingual",
            isAIEnhancementEnabled: true,
            selectedTranscriptionModelName: multilingualWhisper.selectionKey,
            selectedLanguage: "auto",
            allowedAutoDetectLanguages: ["en", "fr"]
        )
        var draft = ModeConfigDraft(mode: .edit(mode), modeManager: ModeManager.shared)
        #expect(draft.allowedAutoDetectLanguages == ["en", "fr"])

        draft.useCompatibleLanguage(for: nemotronLatin)
        #expect(draft.allowedAutoDetectLanguages == ["en-US", "fr-FR"])

        draft.useCompatibleLanguage(for: multilingualWhisper)
        #expect(draft.allowedAutoDetectLanguages == ["en", "fr"])

        let savedWithSubset = draft.makeConfig(mode: .edit(mode))
        #expect(savedWithSubset.allowedAutoDetectLanguages == ["en", "fr"])

        draft.allowedAutoDetectLanguages = []
        let savedCleared = draft.makeConfig(mode: .edit(mode))
        #expect(savedCleared.allowedAutoDetectLanguages == nil)
    }
}

// MARK: - AI Enhancement prompt constraint

@MainActor
struct ScopedAutoDetectEnhancementPromptTests {
    private func makeEnhancementService() throws -> (AIEnhancementService, AIService) {
        let schema = Schema([Transcription.self, VocabularyWord.self, WordReplacement.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let aiService = AIService()
        let service = AIEnhancementService(aiService: aiService, modelContext: container.mainContext)
        return (service, aiService)
    }

    @Test func systemMessageIncludesAllowedLanguagesConstraintWhenConfigured() throws {
        let (service, _) = try makeEnhancementService()
        let prompt = CustomPrompt(title: "Clean", promptText: "Clean up dictation.")
        let configuration = EnhancementRuntimeConfiguration(
            mode: nil,
            isEnabled: true,
            prompt: prompt,
            provider: .groq,
            modelName: "llama",
            useClipboardContext: false,
            useSelectedTextContext: false,
            useScreenCaptureContext: false,
            allowedAutoDetectLanguages: ["en", "fr"]
        )

        let systemMessage = service.systemMessageForTesting(prompt: prompt, configuration: configuration)
        #expect(systemMessage.contains("<ALLOWED_LANGUAGES>"))
        #expect(systemMessage.contains("English (en), French (fr)"))
        #expect(systemMessage.contains("code-switching"))
        #expect(systemMessage.contains("Do not translate"))

        // replacingPrompt preserves the language constraint (used in History re-enhancement).
        let altPrompt = CustomPrompt(title: "Formal", promptText: "Make it formal.")
        let replaced = configuration.replacingPrompt(altPrompt)
        #expect(replaced.allowedAutoDetectLanguages == ["en", "fr"])
    }

    @Test func systemMessageOmitsAllowedLanguagesConstraintWhenUnconstrained() throws {
        let (service, _) = try makeEnhancementService()
        let prompt = CustomPrompt(title: "Clean", promptText: "Clean up dictation.")
        let configuration = EnhancementRuntimeConfiguration(
            mode: nil,
            isEnabled: true,
            prompt: prompt,
            provider: .groq,
            modelName: "llama",
            useClipboardContext: false,
            useSelectedTextContext: false,
            useScreenCaptureContext: false,
            allowedAutoDetectLanguages: []
        )

        let systemMessage = service.systemMessageForTesting(prompt: prompt, configuration: configuration)
        #expect(!systemMessage.contains("<ALLOWED_LANGUAGES>"))
        #expect(systemMessage == prompt.finalPromptText)
    }

    @Test func modeRuntimeResolverAppliesConstraintOnlyForAutoDetectModes() throws {
        let (service, aiService) = try makeEnhancementService()

        let autoMode = ModeConfig(
            name: "Bilingual",
            isAIEnhancementEnabled: true,
            selectedTranscriptionModelName: "parakeet-tdt-0.6b-v3",
            selectedLanguage: "auto",
            allowedAutoDetectLanguages: ["en", "fr"]
        )
        let autoConfig = ModeRuntimeResolver.currentEnhancementConfiguration(
            mode: autoMode,
            enhancementService: service,
            aiService: aiService
        )
        #expect(autoConfig.allowedAutoDetectLanguages == ["en", "fr"])

        let clearedMode = ModeConfig(
            name: "Unconstrained",
            isAIEnhancementEnabled: true,
            selectedTranscriptionModelName: "parakeet-tdt-0.6b-v3",
            selectedLanguage: "auto",
            allowedAutoDetectLanguages: []
        )
        let clearedConfig = ModeRuntimeResolver.currentEnhancementConfiguration(
            mode: clearedMode,
            enhancementService: service,
            aiService: aiService
        )
        #expect(clearedConfig.allowedAutoDetectLanguages.isEmpty)

        let singleLanguageMode = ModeConfig(
            name: "Locked English",
            isAIEnhancementEnabled: true,
            selectedTranscriptionModelName: "ggml-large-v3-turbo",
            selectedLanguage: "en",
            allowedAutoDetectLanguages: ["en", "fr"]
        )
        let singleConfig = ModeRuntimeResolver.currentEnhancementConfiguration(
            mode: singleLanguageMode,
            enhancementService: service,
            aiService: aiService
        )
        #expect(singleConfig.allowedAutoDetectLanguages.isEmpty)

        let englishOnlyModelMode = ModeConfig(
            name: "English-Only Model",
            isAIEnhancementEnabled: true,
            selectedTranscriptionModelName: "ggml-tiny.en",
            selectedLanguage: "auto",
            allowedAutoDetectLanguages: ["en", "fr"]
        )
        let englishOnlyConfig = ModeRuntimeResolver.currentEnhancementConfiguration(
            mode: englishOnlyModelMode,
            enhancementService: service,
            aiService: aiService
        )
        #expect(englishOnlyConfig.allowedAutoDetectLanguages.isEmpty)
    }
}

// MARK: - End-to-end Whisper transcription tests

struct WhisperScopedAutoDetectEndToEndTests {
    private static func findMultilingualWhisperModelPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".cache/whisper-cpp/ggml-large-v3-turbo-q5_0.bin"),
            home.appendingPathComponent("Library/Application Support/com.prakashjoshipax.VoiceInk/WhisperModels/ggml-large-v3-turbo-q5_0.bin"),
            home.appendingPathComponent("Library/Application Support/com.prakashjoshipax.VoiceInk/WhisperModels/ggml-large-v3-turbo.bin"),
            home.appendingPathComponent("Library/Application Support/com.prakashjoshipax.VoiceInk/WhisperModels/ggml-base.bin"),
            home.appendingPathComponent("Library/Application Support/com.prakashjoshipax.VoiceInk/WhisperModels/ggml-tiny.bin"),
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate.path
        }
        return nil
    }

    private static func synthesizePCM16kSamples(text: String, preferredVoices: [String]) throws -> [Float] {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInkScopedLangTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let aiffURL = tempDir.appendingPathComponent("clip.aiff")
        let wavURL = tempDir.appendingPathComponent("clip.wav")

        let availableVoices = availableSayVoices()
        let selectedVoice = preferredVoices.first { availableVoices.contains($0) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var sayArgs: [String] = []
        if let selectedVoice {
            sayArgs += ["-v", selectedVoice]
        }
        sayArgs += ["-o", aiffURL.path, text]
        say.arguments = sayArgs
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else {
            throw NSError(domain: "WhisperScopedAutoDetectEndToEndTests", code: Int(say.terminationStatus))
        }

        let afconvert = Process()
        afconvert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        afconvert.arguments = [
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            aiffURL.path,
            wavURL.path,
        ]
        try afconvert.run()
        afconvert.waitUntilExit()
        guard afconvert.terminationStatus == 0 else {
            throw NSError(domain: "WhisperScopedAutoDetectEndToEndTests", code: Int(afconvert.terminationStatus))
        }

        let data = try Data(contentsOf: wavURL)
        let dataChunkMarker = Data("data".utf8)
        let pcmStartOffset: Int
        if let markerRange = data.range(of: dataChunkMarker) {
            pcmStartOffset = markerRange.upperBound + 4
        } else {
            pcmStartOffset = 44
        }
        guard pcmStartOffset < data.count else { return [] }
        return stride(from: pcmStartOffset, to: data.count - 1, by: 2).map { offset in
            data[offset..<(offset + 2)].withUnsafeBytes { bytes in
                let sample = Int16(littleEndian: bytes.load(as: Int16.self))
                return max(-1.0, min(Float(sample) / 32767.0, 1.0))
            }
        }
    }

    private static func availableSayVoices() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        var voices = Set<String>()
        for line in output.split(separator: "\n") {
            if let range = line.range(of: #"\s+[a-z]{2,3}_[A-Z]{2}\b"#, options: .regularExpression) {
                voices.insert(String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces))
            }
        }
        return voices
    }

    @Test(.enabled(if: findMultilingualWhisperModelPath() != nil))
    func whisperEndToEndScopedAutoDetectSelectsStrictlyBetweenEnglishAndFrench() async throws {
        let modelPath = try #require(Self.findMultilingualWhisperModelPath())
        let context = try await WhisperContext.createContext(path: modelPath)
        defer {
            Task { await context.releaseResources() }
        }

        // 1. English clip with allowed = [en, fr] -> selects "en" and transcribes English.
        let englishSamples = try Self.synthesizePCM16kSamples(
            text: "Hello, this is a clear test of English speech recognition.",
            preferredVoices: ["Samantha", "Daniel", "Alex", "Eddy (English (US))"]
        )
        let englishRequest = TranscriptionRequestContext(
            language: "auto",
            prompt: nil,
            allowedAutoDetectLanguages: ["en", "fr"]
        )
        let englishText = try await context.transcribe(samples: englishSamples, request: englishRequest)
        let englishDetected = await context.lastDetectedLanguageCode
        #expect(englishDetected == "en")
        #expect(englishText.localizedCaseInsensitiveContains("english") || englishText.localizedCaseInsensitiveContains("hello"))

        // 2. French clip with allowed = [en, fr] -> selects "fr" and transcribes French.
        let frenchSamples = try Self.synthesizePCM16kSamples(
            text: "Bonjour, ceci est un test de reconnaissance vocale en français.",
            preferredVoices: ["Thomas", "Amélie", "Audrey", "Eddy (French (France))"]
        )
        let frenchProbs = await context.detectLanguageProbabilities(samples: frenchSamples)
        let frenchRequest = TranscriptionRequestContext(
            language: "auto",
            prompt: nil,
            allowedAutoDetectLanguages: ["en", "fr"]
        )
        let frenchText = try await context.transcribe(samples: frenchSamples, request: frenchRequest)
        let frenchDetected = await context.lastDetectedLanguageCode
        #expect(
            frenchDetected == "fr",
            "Expected fr, got \(frenchDetected ?? "nil") (rawTop=\(frenchProbs.topLanguage ?? "nil"), en=\(frenchProbs.probabilities["en"] ?? -1), fr=\(frenchProbs.probabilities["fr"] ?? -1), text=\(frenchText))"
        )
        #expect(frenchText.localizedCaseInsensitiveContains("bonjour") || frenchText.localizedCaseInsensitiveContains("français"))

        // 3. Third-language clip (Spanish) with allowed = [en, fr] -> MUST pick strictly from {en, fr}, never "es".
        let spanishSamples = try Self.synthesizePCM16kSamples(
            text: "Buenos días, esta es una prueba de transcripción en español para verificar el idioma.",
            preferredVoices: ["Mónica", "Paulina", "Jorge", "Eddy (Spanish (Spain))"]
        )
        let constrainedSpanishRequest = TranscriptionRequestContext(
            language: "auto",
            prompt: nil,
            allowedAutoDetectLanguages: ["en", "fr"]
        )
        _ = try await context.transcribe(samples: spanishSamples, request: constrainedSpanishRequest)
        let constrainedSpanishDetected = await context.lastDetectedLanguageCode
        #expect(constrainedSpanishDetected == "en" || constrainedSpanishDetected == "fr")

        // 4. Clearing allowedAutoDetectLanguages restores unconstrained Auto-detect (detects Spanish as "es").
        let unconstrainedSpanishRequest = TranscriptionRequestContext(
            language: "auto",
            prompt: nil,
            allowedAutoDetectLanguages: []
        )
        _ = try await context.transcribe(samples: spanishSamples, request: unconstrainedSpanishRequest)
        let unconstrainedSpanishDetected = await context.lastDetectedLanguageCode
        #expect(unconstrainedSpanishDetected == "es")

        // 5. Single-language mode ("fr") ignores allowedAutoDetectLanguages and keeps French.
        let lockedFrenchRequest = TranscriptionRequestContext(
            language: "fr",
            prompt: nil,
            allowedAutoDetectLanguages: ["en"]
        )
        _ = try await context.transcribe(samples: englishSamples, request: lockedFrenchRequest)
        let lockedFrenchDetected = await context.lastDetectedLanguageCode
        #expect(lockedFrenchDetected == "fr")
    }
}
