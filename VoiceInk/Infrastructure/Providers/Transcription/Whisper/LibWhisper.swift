import Foundation
import os

#if canImport(whisper)
    import whisper
#else
    #error("Unable to import whisper module. Please check your project configuration.")
#endif

// Meet Whisper C++ constraint: Don't access from more than one thread at a time.
actor WhisperContext {
    private var context: OpaquePointer?
    private var language: String?
    private var allowedAutoDetectLanguages: [String] = []
    private var prompt: String?
    private var vadModelPath: String?
    private(set) var lastDetectedLanguageCode: String?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperContext")

    private init() {}

    init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        if let context = context {
            whisper_free(context)
        }
    }

    /// Keep request settings, inference and result retrieval in one actor operation.
    func transcribe(samples: [Float], request: TranscriptionRequestContext) throws -> String {
        try Task.checkCancellation()
        let previousLanguage = language
        let previousAllowedAutoDetectLanguages = allowedAutoDetectLanguages
        let previousPrompt = prompt
        defer {
            language = previousLanguage
            allowedAutoDetectLanguages = previousAllowedAutoDetectLanguages
            prompt = previousPrompt
        }
        language = request.language
        allowedAutoDetectLanguages = request.allowedAutoDetectLanguages
        lastDetectedLanguageCode = nil
        // whisper.cpp tokenizes the prompt and retains its trailing tokens within its own context limit.
        prompt = [request.prompt ?? "", request.vocabulary?.terms.joined(separator: ", ") ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        guard fullTranscribe(samples: samples) else { throw VoiceInkEngineError.whisperCoreFailed }
        try Task.checkCancellation()
        return getTranscription()
    }

    func fullTranscribe(samples: [Float]) -> Bool {
        guard let context = context else { return false }

        let maxThreads = max(1, min(8, cpuCount() - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        let selectedLanguage = language ?? "auto"
        let effectiveLanguage: String
        if selectedLanguage == "auto" {
            effectiveLanguage = resolveScopedAutoDetectLanguage(
                for: samples,
                allowedLanguages: allowedAutoDetectLanguages,
                nThreads: Int32(maxThreads),
                context: context
            ) ?? "auto"
        } else {
            effectiveLanguage = selectedLanguage
        }

        let effectiveLanguageParam: String? = effectiveLanguage != "auto" ? effectiveLanguage : nil
        let effectivePromptParam: String? = prompt

        // whisper.cpp otherwise feeds each 30 s window's decoded text into the next window, so one
        // repeating window repeats until the end of long recordings. Give the context budget only to
        // the prompt (plus the <|prev|> token) and repeat it in every window, leaving none for decoded text.
        params.n_max_text_ctx = 0
        if let prompt, !prompt.isEmpty {
            var tokens = [whisper_token](repeating: 0, count: 512)
            let tokenCount = whisper_tokenize(context, prompt, &tokens, Int32(tokens.count))
            // A negative count means the prompt needs that many tokens; whisper.cpp keeps its tail.
            let promptTokenCount = abs(tokenCount)
            if promptTokenCount > 0 {
                params.carry_initial_prompt = true
                params.n_max_text_ctx = promptTokenCount + 1
            }
        }

        params.print_realtime = true
        params.print_progress = false
        params.print_timestamps = true
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(maxThreads)
        params.offset_ms = 0
        params.no_context = true
        params.single_segment = false
        params.temperature = 0.2

        whisper_reset_timings(context)

        // Configure VAD if enabled by user and model is available
        let isVADEnabled = UserDefaults.standard.bool(forKey: "IsVADEnabled")
        let effectiveVADModelPath: String?
        if isVADEnabled, let vadModelPath = self.vadModelPath {
            params.vad = true
            effectiveVADModelPath = vadModelPath

            var vadParams = whisper_vad_default_params()
            vadParams.threshold = 0.50
            vadParams.min_speech_duration_ms = 250
            vadParams.min_silence_duration_ms = 100
            vadParams.max_speech_duration_s = Float.greatestFiniteMagnitude
            vadParams.speech_pad_ms = 30
            vadParams.samples_overlap = 0.1
            params.vad_params = vadParams
        } else {
            params.vad = false
            effectiveVADModelPath = nil
        }

        var success = true
        withOptionalCString(effectiveLanguageParam) { languagePtr in
            params.language = languagePtr
            withOptionalCString(effectivePromptParam) { promptPtr in
                params.initial_prompt = promptPtr
                withOptionalCString(effectiveVADModelPath) { vadPathPtr in
                    params.vad_model_path = vadPathPtr
                    samples.withUnsafeBufferPointer { samplesBuffer in
                        if whisper_full(context, params, samplesBuffer.baseAddress, Int32(samplesBuffer.count)) != 0 {
                            logger.error("❌ Failed to run whisper_full. VAD enabled: \(params.vad, privacy: .public)")
                            success = false
                        }
                    }
                }
            }
        }

        if success {
            let detectedID = whisper_full_lang_id(context)
            if detectedID >= 0, let cStr = whisper_lang_str(detectedID) {
                lastDetectedLanguageCode = String(cString: cStr)
            } else {
                lastDetectedLanguageCode = nil
            }
        }

        return success
    }

    func detectLanguageProbabilities(samples: [Float]) -> (topLanguage: String?, probabilities: [String: Float]) {
        guard let context, whisper_is_multilingual(context) != 0, !samples.isEmpty else {
            return (nil, [:])
        }
        let maxThreads = Int32(max(1, min(8, cpuCount() - 2)))
        let detectionSampleCount = min(samples.count, 30 * 16_000)
        let melResult: Int32 = samples.withUnsafeBufferPointer { buffer in
            whisper_pcm_to_mel(context, buffer.baseAddress, Int32(detectionSampleCount), maxThreads)
        }
        guard melResult == 0 else { return (nil, [:]) }
        let maxLangID = Int(whisper_lang_max_id())
        guard maxLangID >= 0 else { return (nil, [:]) }
        var probs = [Float](repeating: 0, count: maxLangID + 1)
        let topID: Int32 = probs.withUnsafeMutableBufferPointer { buffer in
            whisper_lang_auto_detect(context, 0, maxThreads, buffer.baseAddress)
        }
        guard topID >= 0 else { return (nil, [:]) }
        let topLanguage = whisper_lang_str(topID).map { String(cString: $0) }
        var byCode: [String: Float] = [:]
        for id in 0...maxLangID {
            if let cStr = whisper_lang_str(Int32(id)) {
                byCode[String(cString: cStr)] = probs[id]
            }
        }
        return (topLanguage, byCode)
    }

    private func resolveScopedAutoDetectLanguage(
        for samples: [Float],
        allowedLanguages: [String],
        nThreads: Int32,
        context: OpaquePointer
    ) -> String? {
        let normalized = AutoDetectLanguageScope.normalize(allowedLanguages)
        guard !normalized.isEmpty else {
            return nil
        }

        guard whisper_is_multilingual(context) != 0 else {
            return "en"
        }

        let candidates = whisperCandidates(for: normalized)
        guard !candidates.isEmpty else {
            logger.warning("Scoped auto-detect languages did not match any Whisper language ID; using unconstrained auto-detect.")
            return nil
        }

        if candidates.count == 1 {
            logger.notice("Scoped auto-detect using single allowed Whisper language: \(candidates[0].code, privacy: .public)")
            return candidates[0].code
        }

        guard !samples.isEmpty else {
            return candidates[0].code
        }

        // Whisper language detection evaluates the first 30-second encoder window (16 kHz * 30 s).
        let detectionSampleCount = min(samples.count, 30 * 16_000)
        let melResult: Int32 = samples.withUnsafeBufferPointer { buffer in
            whisper_pcm_to_mel(context, buffer.baseAddress, Int32(detectionSampleCount), nThreads)
        }
        guard melResult == 0 else {
            logger.error(
                "Failed to compute mel spectrogram for scoped language detection (code \(melResult, privacy: .public)); defaulting to \(candidates[0].code, privacy: .public)"
            )
            return candidates[0].code
        }

        let maxLangID = Int(whisper_lang_max_id())
        guard maxLangID >= 0 else {
            return candidates[0].code
        }

        var probabilities = [Float](repeating: 0, count: maxLangID + 1)
        let topLangID: Int32 = probabilities.withUnsafeMutableBufferPointer { buffer in
            whisper_lang_auto_detect(context, 0, nThreads, buffer.baseAddress)
        }
        guard topLangID >= 0 else {
            logger.error(
                "Failed to run Whisper language auto-detection (code \(topLangID, privacy: .public)); defaulting to \(candidates[0].code, privacy: .public)"
            )
            return candidates[0].code
        }

        let selected = WhisperAutoDetectLanguageSelector.selectBestLanguage(
            probabilities: probabilities,
            allowedCandidates: candidates
        ) ?? candidates[0]

        let selectedProb = Int(selected.languageID) < probabilities.count ? probabilities[Int(selected.languageID)] : 0
        logger.notice(
            "Scoped auto-detect selected \(selected.code, privacy: .public) (p=\(selectedProb, format: .fixed(precision: 4), privacy: .public)) from [\(candidates.map(\.code).joined(separator: ", "), privacy: .public)]"
        )
        return selected.code
    }

    private func whisperCandidates(for allowedLanguages: [String]) -> [WhisperLanguageCandidate] {
        var seenIDs = Set<Int32>()
        var candidates: [WhisperLanguageCandidate] = []

        for rawCode in allowedLanguages {
            let lower = rawCode.lowercased()
            let base = AutoDetectLanguageScope.primaryLanguageSubtag(of: lower)
            let directID = lower.withCString { whisper_lang_id($0) }
            let langID = directID >= 0 ? directID : base.withCString { whisper_lang_id($0) }
            guard langID >= 0, seenIDs.insert(langID).inserted else { continue }
            let canonicalCode = whisper_lang_str(langID).map { String(cString: $0) } ?? base
            candidates.append(WhisperLanguageCandidate(languageID: langID, code: canonicalCode))
        }

        return candidates
    }

    func getTranscription() -> String {
        guard let context = context else { return "" }
        var transcription = ""
        for i in 0..<whisper_full_n_segments(context) {
            transcription += String(cString: whisper_full_get_segment_text(context, i))
        }
        return transcription
    }

    static func createContext(path: String) async throws -> WhisperContext {
        let whisperContext = WhisperContext()
        try await whisperContext.initializeModel(path: path)

        // Load VAD model from bundle resources
        let vadModelPath = await VADModelManager.shared.getModelPath()
        await whisperContext.setVADModelPath(vadModelPath)

        return whisperContext
    }

    private func initializeModel(path: String) throws {
        var params = whisper_context_default_params()
        #if targetEnvironment(simulator)
            params.use_gpu = false
            logger.info("Running on the simulator, using CPU")
        #else
            params.flash_attn = true  // Enable flash attention for Metal
            logger.info("Flash attention enabled for Metal")
        #endif

        let context = whisper_init_from_file_with_params(path, params)
        if let context {
            self.context = context
        } else {
            logger.error("❌ Couldn't load model at \(path, privacy: .public)")
            throw VoiceInkEngineError.modelLoadFailed
        }
    }

    private func setVADModelPath(_ path: String?) {
        self.vadModelPath = path
        if path != nil {
            logger.info("VAD model loaded from bundle resources")
        }
    }

    func releaseResources() {
        if let context = context {
            whisper_free(context)
            self.context = nil
        }
    }

    func setPrompt(_ prompt: String?) {
        self.prompt = prompt
    }

    func setLanguage(_ language: String?) {
        self.language = language
    }
}

fileprivate func withOptionalCString<Result>(
    _ string: String?,
    _ body: (UnsafePointer<CChar>?) -> Result
) -> Result {
    guard let string else {
        return body(nil)
    }
    return string.withCString(body)
}

fileprivate func cpuCount() -> Int {
    ProcessInfo.processInfo.processorCount
}
