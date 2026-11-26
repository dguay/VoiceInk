import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import VoiceInk

// MARK: - Fakes

private struct WarmTestModel: TranscriptionModel {
    let id = UUID()
    let name: String
    var displayName: String { "Model \(name)" }
    let description = "Test model"
    let provider: ModelProvider = .groq
    let isMultilingualModel = false
    let supportedLanguages: [String: String] = ["en": "English"]
}

/// Counts model loads the way a local service does: a load only when the model is not loaded yet.
@MainActor
private final class LoadCountingTranscriber: AudioFileTranscriber {
    let output: String
    private(set) var loadedModelName: String?
    private(set) var loadCount = 0
    private(set) var transcribedModelNames: [String] = []
    private(set) var cleanupCount = 0

    init(output: String) {
        self.output = output
    }

    func prepare(model: any TranscriptionModel) async throws {
        guard loadedModelName != model.name else { return }
        loadedModelName = model.name
        loadCount += 1
    }

    func transcribe(
        audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> String {
        transcribedModelNames.append(model.name)
        return output
    }

    func cleanup() async {
        cleanupCount += 1
        loadedModelName = nil
    }
}

@MainActor
private final class TranscriberFactory {
    let output: String
    private(set) var made: [LoadCountingTranscriber] = []

    init(output: String = "secret dictated words") {
        self.output = output
    }

    func make() -> any AudioFileTranscriber {
        let transcriber = LoadCountingTranscriber(output: output)
        made.append(transcriber)
        return transcriber
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("WarmTranscriberTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A one-second 440 Hz tone in an m4a container, like an Android recording.
private func makeRecording(in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("recording-\(UUID().uuidString).m4a")
    let sampleRate = 44_100.0
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames = AVAudioFrameCount(sampleRate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
    buffer.frameLength = frames
    let channel = try #require(buffer.floatChannelData?[0])
    for frame in 0..<Int(frames) {
        channel[frame] = Float(sin(2 * .pi * 440 * Double(frame) / sampleRate)) * 0.3
    }
    try file.write(from: buffer)
    return url
}

// MARK: - Pipeline

@MainActor
@Suite(.serialized)
struct PhoneDictationWarmTranscriberTests {
    private final class ModelBox {
        var name = "parakeet-a"
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Transcription.self, VocabularyWord.self, WordReplacement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func pipeline(
        context: ModelContext, factory: TranscriberFactory, model: ModelBox, recordings: URL, warm: Bool
    ) -> AudioFileTranscriptionPipeline {
        AudioFileTranscriptionPipeline(
            modelContext: context,
            dependencies: .init(
                resolveConfiguration: { mode in
                    TranscriptionRuntimeConfiguration(
                        mode: mode, model: WarmTestModel(name: model.name), language: "en",
                        isRealtimeEnabled: false)
                },
                makeTranscriber: { factory.make() },
                enhancementService: nil,
                recordingsDirectory: recordings
            ),
            keepsTranscriberWarm: warm
        )
    }

    private let mode = ModeConfig(name: "Phone", isAIEnhancementEnabled: false)

    @Test func twoPhoneRequestsWithTheSameModelLoadItOnce() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = TranscriberFactory()
        let pipeline = pipeline(
            context: try makeContext(), factory: factory, model: ModelBox(),
            recordings: directory.appendingPathComponent("R"), warm: true)

        let first = try await pipeline.transcribe(
            audioURL: try makeRecording(in: directory), mode: mode, source: .phone)
        let second = try await pipeline.transcribe(
            audioURL: try makeRecording(in: directory), mode: mode, source: .phone)

        #expect(factory.made.count == 1)
        let transcriber = try #require(factory.made.first)
        #expect(transcriber.loadCount == 1)
        #expect(transcriber.cleanupCount == 0)
        #expect(transcriber.transcribedModelNames == ["parakeet-a", "parakeet-a"])
        #expect(!first.timings.reusedWarmTranscriber)
        #expect(second.timings.reusedWarmTranscriber)
        #expect(second.finalText == "secret dictated words")

        await pipeline.releaseWarmTranscriber()
        #expect(transcriber.cleanupCount == 1)

        // After a release the next request starts cold again.
        let third = try await pipeline.transcribe(
            audioURL: try makeRecording(in: directory), mode: mode, source: .phone)
        #expect(factory.made.count == 2)
        #expect(!third.timings.reusedWarmTranscriber)
    }

    @Test func changingTheModelBetweenRequestsLoadsTheNewOneAndReleasesTheOld() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = TranscriberFactory()
        let model = ModelBox()
        let pipeline = pipeline(
            context: try makeContext(), factory: factory, model: model,
            recordings: directory.appendingPathComponent("R"), warm: true)

        _ = try await pipeline.transcribe(audioURL: try makeRecording(in: directory), mode: mode, source: .phone)
        model.name = "parakeet-b"
        let second = try await pipeline.transcribe(
            audioURL: try makeRecording(in: directory), mode: mode, source: .phone)

        #expect(factory.made.count == 2)
        let old = factory.made[0]
        let new = factory.made[1]
        #expect(old.cleanupCount == 1)
        #expect(old.transcribedModelNames == ["parakeet-a"])
        #expect(new.cleanupCount == 0)
        #expect(new.loadCount == 1)
        #expect(new.transcribedModelNames == ["parakeet-b"])
        #expect(!second.timings.reusedWarmTranscriber)
        #expect(second.transcription.transcriptionModelName == "Model parakeet-b")
    }

    @Test func audioImportStillMakesAndCleansUpAFreshTranscriberPerFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = TranscriberFactory()
        let pipeline = pipeline(
            context: try makeContext(), factory: factory, model: ModelBox(),
            recordings: directory.appendingPathComponent("R"), warm: false)

        let first = try await pipeline.transcribe(audioURL: try makeRecording(in: directory), mode: mode)
        let second = try await pipeline.transcribe(audioURL: try makeRecording(in: directory), mode: mode)

        #expect(factory.made.count == 2)
        #expect(factory.made.allSatisfy { $0.cleanupCount == 1 && $0.loadCount == 1 })
        #expect(!first.timings.reusedWarmTranscriber)
        #expect(!second.timings.reusedWarmTranscriber)

        // Releasing does nothing without a warm transcriber.
        await pipeline.releaseWarmTranscriber()
        #expect(factory.made.allSatisfy { $0.cleanupCount == 1 })
    }

    @Test func aPhoneRequestReportsEveryStepAndNoText() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = TranscriberFactory(output: "secret dictated words")
        let pipeline = pipeline(
            context: try makeContext(), factory: factory, model: ModelBox(),
            recordings: directory.appendingPathComponent("R"), warm: true)

        let result = try await pipeline.transcribe(
            audioURL: try makeRecording(in: directory), mode: mode, source: .phone)

        let timings = result.timings
        #expect(timings.audioConversion > 0)
        #expect(timings.modelLoad >= 0)
        #expect(timings.transcription >= 0)
        #expect(timings.enhancement == nil)
        #expect(timings.total >= timings.audioConversion + timings.modelLoad + timings.transcription)

        let line = timings.logDescription
        for step in ["audioConversion=", "modelLoad=", "transcription=", "aiCleanup=skipped", "total="] {
            #expect(line.contains(step))
        }
        #expect(line.contains("(cold)"))
        #expect(!line.contains("secret"))
        #expect(!line.contains("dictated"))
        #expect(!line.contains(result.finalText))
    }
}

// MARK: - Timings and warm transcriber

@MainActor
struct WarmAudioFileTranscriberTests {
    @Test func logLineFormatsEachStepInSeconds() {
        let timings = AudioFileTranscriptionTimings(
            audioConversion: 0.1234, modelLoad: 0, reusedWarmTranscriber: true, transcription: 1.5,
            enhancement: 0.75, total: 2.4)

        #expect(
            timings.logDescription
                == "audioConversion=0.123s modelLoad=0.000s (warm) transcription=1.500s aiCleanup=0.750s total=2.400s"
        )
    }

    @Test func releaseWhileARequestRunsWaitsUntilItIsCheckedIn() async throws {
        let factory = TranscriberFactory()
        let warm = WarmAudioFileTranscriber(makeTranscriber: { factory.make() })
        let model = WarmTestModel(name: "parakeet-a")

        let lease = await warm.checkOut(for: model)
        await warm.release()
        let transcriber = try #require(factory.made.first)
        #expect(transcriber.cleanupCount == 0)
        #expect(warm.isHoldingTranscriber)

        await warm.checkIn(lease)
        #expect(transcriber.cleanupCount == 1)
        #expect(!warm.isHoldingTranscriber)
    }

    @Test func aSecondCallerWhileBusyGetsItsOwnTranscriberThatIsCleanedUp() async {
        let factory = TranscriberFactory()
        let warm = WarmAudioFileTranscriber(makeTranscriber: { factory.make() })
        let model = WarmTestModel(name: "parakeet-a")

        let first = await warm.checkOut(for: model)
        let second = await warm.checkOut(for: model)
        #expect(factory.made.count == 2)
        #expect(!second.isReused)

        await warm.checkIn(second)
        #expect(factory.made[1].cleanupCount == 1)
        await warm.checkIn(first)
        #expect(factory.made[0].cleanupCount == 0)

        let again = await warm.checkOut(for: model)
        #expect(again.isReused)
        #expect(again.transcriber === factory.made[0])
        await warm.checkIn(again)
    }
}
