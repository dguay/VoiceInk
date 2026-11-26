import Foundation
import os

// MARK: - Step timings

/// How long each step of one `AudioFileTranscriptionPipeline` run took, in seconds.
///
/// It only holds numbers, so its log line can be public: it never contains transcript text,
/// dictated content or audio.
struct AudioFileTranscriptionTimings: Equatable, Sendable {
    /// Decoding the upload and writing the 16 kHz WAV kept in Recordings.
    var audioConversion: TimeInterval = 0
    /// Getting a transcriber for the model and loading the model into it. Near zero when a warm
    /// transcriber already holds the model.
    var modelLoad: TimeInterval = 0
    /// Whether the transcriber (and its loaded model) was reused from an earlier request.
    var reusedWarmTranscriber = false
    /// The transcription call itself.
    var transcription: TimeInterval = 0
    /// AI enhancement ("AI cleanup"), or nil when it was skipped.
    var enhancement: TimeInterval?
    /// The whole pipeline run, including saving to History.
    var total: TimeInterval = 0

    /// One line with every step, for example
    /// `audioConversion=0.120s modelLoad=0.000s (warm) transcription=0.850s aiCleanup=skipped total=1.010s`.
    var logDescription: String {
        let load = "modelLoad=\(Self.format(modelLoad))" + (reusedWarmTranscriber ? " (warm)" : " (cold)")
        let cleanup = enhancement.map { "aiCleanup=\(Self.format($0))" } ?? "aiCleanup=skipped"
        return [
            "audioConversion=\(Self.format(audioConversion))",
            load,
            "transcription=\(Self.format(transcription))",
            cleanup,
            "total=\(Self.format(total))",
        ].joined(separator: " ")
    }

    private static func format(_ seconds: TimeInterval) -> String {
        String(format: "%.3fs", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds))
    }
}

extension Duration {
    /// The duration in seconds, as a `TimeInterval`.
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

// MARK: - Model preloading

extension TranscriptionServiceRegistry {
    /// Loads `model` into the service that will transcribe it, so the load can be timed apart
    /// from the transcription. Models whose service loads lazily (Whisper, Nemotron, cloud and
    /// Apple models) are left to `transcribe`, as before.
    func prepare(model: any TranscriptionModel) async throws {
        if let fluidAudioModel = model as? FluidAudioModel {
            try await fluidAudioTranscriptionService.loadModel(for: fluidAudioModel)
        } else if let transcribeCppModel = model as? TranscribeCppModel {
            try await transcribeCppTranscriptionService.loadModel(for: transcribeCppModel)
        }
    }
}

// MARK: - Warm transcriber

/// Keeps one transcriber, and so its loaded local model, alive between pipeline runs.
///
/// Phone dictation uses it so that only the first request after launch, after a model change or
/// after `release()` pays the model load. Audio Import does not: it still builds a fresh
/// transcriber per file and cleans it up afterwards.
///
/// Why a separate instance instead of the engine's registry: the Mac dictation cleans up the
/// engine's `TranscriptionServiceRegistry` after every recording (`VoiceInkEngine.cleanupResources`),
/// which would unload a model in the middle of a phone transcription, and the engine loads and
/// unloads models on its own schedule. A phone-owned instance can never interfere with a Mac
/// dictation running at the same time. The cost is memory: while phone dictation is on and has
/// served a request, its model stays loaded next to the Mac's copy (for Parakeet roughly the
/// size of the model on disk, a few hundred MB). It is released when the model changes and when
/// phone dictation is turned off or the app quits.
///
/// Whisper models are not kept warm by this: `WhisperTranscriptionService` reuses the model the
/// Mac has loaded when it is the same one, and otherwise loads and frees its own context per call.
@MainActor
final class WarmAudioFileTranscriber {
    /// A transcriber handed to one pipeline run. Give it back with `checkIn(_:)`.
    struct Lease {
        let transcriber: any AudioFileTranscriber
        /// The transcriber already served an earlier run with the same model.
        let isReused: Bool
        /// A one-off transcriber made because the warm one was busy; cleaned up on check-in.
        fileprivate let isTemporary: Bool
    }

    private let makeTranscriber: @MainActor () -> any AudioFileTranscriber
    private var current: (key: String, transcriber: any AudioFileTranscriber)?
    private var isInUse = false
    private var releaseRequested = false
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "PhoneDictation")

    init(makeTranscriber: @escaping @MainActor () -> any AudioFileTranscriber) {
        self.makeTranscriber = makeTranscriber
    }

    /// Whether a transcriber is currently kept warm.
    var isHoldingTranscriber: Bool { current != nil }

    /// Returns the warm transcriber when it already serves `model`, otherwise releases it and
    /// makes a new one for `model`.
    func checkOut(for model: any TranscriptionModel) async -> Lease {
        // Phone requests are serialized, so this only guards against misuse: a second caller gets
        // its own transcriber rather than sharing one that is busy.
        guard !isInUse else {
            return Lease(transcriber: makeTranscriber(), isReused: false, isTemporary: true)
        }
        isInUse = true

        let key = Self.key(for: model)
        if let current, current.key == key {
            return Lease(transcriber: current.transcriber, isReused: true, isTemporary: false)
        }
        if let previous = current {
            current = nil
            logger.notice("Releasing the warm phone dictation model after a model change")
            await previous.transcriber.cleanup()
        }
        let transcriber = makeTranscriber()
        current = (key, transcriber)
        return Lease(transcriber: transcriber, isReused: false, isTemporary: false)
    }

    /// Ends a run. The warm transcriber stays loaded unless `release()` was called meanwhile.
    func checkIn(_ lease: Lease) async {
        if lease.isTemporary {
            await lease.transcriber.cleanup()
            return
        }
        isInUse = false
        if releaseRequested {
            releaseRequested = false
            await release()
        }
    }

    /// Cleans up and drops the warm transcriber, freeing its model. When a run is using it, the
    /// release happens as soon as that run checks it back in.
    func release() async {
        guard !isInUse else {
            releaseRequested = true
            return
        }
        guard let previous = current else { return }
        current = nil
        logger.notice("Released the warm phone dictation model")
        await previous.transcriber.cleanup()
    }

    private static func key(for model: any TranscriptionModel) -> String {
        "\(model.provider.rawValue)/\(model.name)"
    }
}
