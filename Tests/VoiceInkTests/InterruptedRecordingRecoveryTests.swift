import AVFoundation
import AudioToolbox
import Foundation
import SwiftData
import Testing
@testable import VoiceInk

// MARK: - Fixtures

private struct RecoveryTestModel: TranscriptionModel {
    let id = UUID()
    let name = "recovery-model"
    let displayName = "Recovery Model"
    let description = "Test model"
    let provider: ModelProvider = .groq
    let isMultilingualModel = false
    let supportedLanguages: [String: String] = ["en": "English"]
}

@MainActor
private final class RecordingTranscriber: AudioFileTranscriber {
    let output: String
    private(set) var receivedURLs: [URL] = []

    init(output: String) {
        self.output = output
    }

    func transcribe(
        audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> String {
        receivedURLs.append(audioURL)
        return output
    }

    func cleanup() async {}
}

private let sampleRate = 16_000.0

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordingRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes `frames` of 16 kHz mono PCM the way the recorder does, then abandons the
/// file without closing it, as a crash or force-quit would.
private func writeInterruptedRecording(to url: URL, frames: Int) throws {
    var format = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2,
        mFramesPerPacket: 1,
        mBytesPerFrame: 2,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 16,
        mReserved: 0
    )
    var file: ExtAudioFileRef?
    try #require(
        ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileWAVEType, &format, nil, AudioFileFlags.eraseFile.rawValue, &file
        ) == noErr
    )
    let audioFile = try #require(file)
    try #require(
        ExtAudioFileSetProperty(
            audioFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &format
        ) == noErr
    )

    let chunk = 1_600
    let samples = UnsafeMutablePointer<Int16>.allocate(capacity: chunk)
    defer { samples.deallocate() }
    var written = 0
    while written < frames {
        let count = min(chunk, frames - written)
        for index in 0..<count {
            samples[index] = Int16(truncatingIfNeeded: (written + index) * 37)
        }
        var buffers = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(count * 2),
                mData: samples
            )
        )
        try #require(ExtAudioFileWrite(audioFile, UInt32(count), &buffers) == noErr)
        written += count
    }
    // Deliberately never disposed: the header still reports an empty data chunk.
}

private func playableFrameCount(_ url: URL) throws -> AVAudioFramePosition {
    try AVAudioFile(forReading: url).length
}

@MainActor
private func makeContext() throws -> ModelContext {
    let container = try ModelContainer(
        for: Transcription.self, VocabularyWord.self, WordReplacement.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ModelContext(container)
}

@MainActor
private func allTranscriptions(_ context: ModelContext) throws -> [Transcription] {
    try context.fetch(FetchDescriptor<Transcription>())
}

/// A process ID no live process uses in these tests.
private let exitedProcessID: Int32 = 999_999

// MARK: - Active-session marker lifecycle

@MainActor
@Suite(.serialized)
struct ActiveRecordingMarkerTests {
    @Test func startWritesAMarkerOwnedByThisProcessAndStopRemovesIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActiveRecordingMarkerStore(directory: directory.appendingPathComponent("Markers"))
        let tracker = ActiveRecordingSessionTracker(store: store)
        let audioURL = directory.appendingPathComponent("take.wav")
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

        tracker.recordingDidStart(audioURL: audioURL, startedAt: startedAt)

        let entries = store.entries()
        #expect(entries.count == 1)
        let marker = try #require(entries.first?.marker)
        #expect(marker.audioFilePath == audioURL.path)
        #expect(marker.startedAt == startedAt)
        #expect(marker.processID == ProcessInfo.processInfo.processIdentifier)
        // While this process records, the marker is recognised as live.
        #expect(RecordingProcessIdentity.isRunning(marker))

        tracker.recordingDidStop()
        #expect(store.entries().isEmpty)

        // A second stop, as after a failed start, is harmless.
        tracker.recordingDidStop()
        #expect(store.entries().isEmpty)
    }

    @Test func startingANewRecordingReplacesTheStaleMarker() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActiveRecordingMarkerStore(directory: directory)
        let tracker = ActiveRecordingSessionTracker(store: store)
        let first = directory.appendingPathComponent("first.wav")
        let second = directory.appendingPathComponent("second.wav")

        tracker.recordingDidStart(audioURL: first)
        tracker.recordingDidStart(audioURL: second)

        #expect(store.entries().compactMap(\.marker?.audioFilePath) == [second.path])
    }

    @Test(arguments: [false, true])
    func finishedOrCancelledRecordingsNeverTriggerRecoveryOnRestart(audioDeletedAfterStop: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActiveRecordingMarkerStore(directory: directory.appendingPathComponent("Markers"))
        let tracker = ActiveRecordingSessionTracker(store: store)
        let context = try makeContext()
        let audioURL = directory.appendingPathComponent("take.wav")
        try writeInterruptedRecording(to: audioURL, frames: 8_000)

        // Completing and cancelling both stop the recorder, which ends the session.
        tracker.recordingDidStart(audioURL: audioURL)
        tracker.recordingDidStop()
        if audioDeletedAfterStop {
            try FileManager.default.removeItem(at: audioURL)
        }

        // The next launch sees no marker, even though its process has exited.
        let recovered = InterruptedRecordingRecovery(
            markerStore: store,
            modelContext: context,
            isRecordingOwnerRunning: { _ in false }
        ).recoverInterruptedRecordings()

        #expect(recovered.isEmpty)
        #expect(try allTranscriptions(context).isEmpty)
    }
}

// MARK: - Recording owner identity

struct RecordingProcessIdentityTests {
    private let marker = ActiveRecordingMarker(
        audioFilePath: "/tmp/take.wav",
        startedAt: Date(),
        processID: 4_242,
        bootSessionID: "boot-A",
        processStartTime: 1_800_000_000
    )

    @Test func theOwningProcessIsRunningOnlyWhileItsBootAndStartTimeMatch() {
        #expect(RecordingProcessIdentity.isRunning(marker, bootSessionID: "boot-A") { _ in 1_800_000_000 })
        #expect(!RecordingProcessIdentity.isRunning(marker, bootSessionID: "boot-A") { _ in nil })
    }

    @Test func aProcessThatReusedTheIDAfterAForcedRestartIsNotTheOwner() {
        // After a reboot the same ID may belong to anything, even the new VoiceInk.
        #expect(!RecordingProcessIdentity.isRunning(marker, bootSessionID: "boot-B") { _ in 1_800_000_000 })
        // Within one boot, an ID reused by a later process has a different start time.
        #expect(!RecordingProcessIdentity.isRunning(marker, bootSessionID: "boot-A") { _ in 1_800_000_500 })
    }
}

// MARK: - Finalizing interrupted audio

struct InterruptedWAVFinalizerTests {
    @Test func finalizingAnAbandonedRecordingMakesAllWrittenAudioPlayable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("crash.wav")
        try writeInterruptedRecording(to: url, frames: 24_000)
        #expect((try? playableFrameCount(url)) ?? 0 == 0)

        let result = try InterruptedWAVFinalizer.finalize(url)

        #expect(result.dataByteCount == 48_000)
        #expect(abs(result.duration - 1.5) < 0.0001)
        #expect(try playableFrameCount(url) == 24_000)
    }

    @Test func aTrailingPartialSampleIsDropped() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("crash.wav")
        try writeInterruptedRecording(to: url, frames: 16_000)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(Data([0x7F]))
        try handle.close()

        let result = try InterruptedWAVFinalizer.finalize(url)

        #expect(result.dataByteCount == 32_000)
        #expect(try playableFrameCount(url) == 16_000)
    }

    @Test func anAlreadyClosedRecordingIsLeftIntact() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("closed.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_000))
            buffer.frameLength = 8_000
            try file.write(from: buffer)
        }
        let sizeBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int

        let result = try InterruptedWAVFinalizer.finalize(url)

        #expect(result.dataByteCount == 16_000)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int == sizeBefore)
        #expect(try playableFrameCount(url) == 8_000)
    }

    @Test func aFileThatIsNotWAVIsRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("noise.wav")
        try Data(repeating: 0x41, count: 512).write(to: url)

        #expect(throws: InterruptedWAVFinalizer.FinalizeError.notWAV) {
            try InterruptedWAVFinalizer.finalize(url)
        }
    }
}

// MARK: - Recovery on startup, transcribe and discard

@MainActor
@Suite(.serialized)
struct InterruptedRecordingRecoveryTests {
    @MainActor
    private struct Fixture {
        let directory: URL
        let store: ActiveRecordingMarkerStore
        let context: ModelContext
        let audioURL: URL
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

        func recovery(
            isRecordingOwnerRunning: @escaping (ActiveRecordingMarker) -> Bool = { _ in false }
        ) -> InterruptedRecordingRecovery {
            InterruptedRecordingRecovery(
                markerStore: store, modelContext: context, isRecordingOwnerRunning: isRecordingOwnerRunning)
        }
    }

    private func makeFixture(frames: Int? = 16_000, processID: Int32 = exitedProcessID) throws -> Fixture {
        let directory = try temporaryDirectory()
        let store = ActiveRecordingMarkerStore(directory: directory.appendingPathComponent("Markers"))
        let audioURL = directory.appendingPathComponent("\(UUID().uuidString).wav")
        let fixture = Fixture(directory: directory, store: store, context: try makeContext(), audioURL: audioURL)
        if let frames {
            try writeInterruptedRecording(to: audioURL, frames: frames)
        }
        try store.begin(audioURL: audioURL, startedAt: fixture.startedAt, processID: processID)
        return fixture
    }

    @Test func anInterruptedRecordingBecomesAPlayableRecoveredHistoryEntry() throws {
        let fixture = try makeFixture(frames: 16_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let recovered = fixture.recovery().recoverInterruptedRecordings()

        let transcription = try #require(recovered.first)
        #expect(recovered.count == 1)
        #expect(try allTranscriptions(fixture.context).map(\.id) == [transcription.id])
        #expect(transcription.isRecoveredRecording)
        #expect(transcription.text == Transcription.recoveredTranscriptionText)
        #expect(transcription.audioFileURL == fixture.audioURL.absoluteString)
        #expect(transcription.timestamp == fixture.startedAt)
        #expect(abs(transcription.duration - 1.0) < 0.0001)
        #expect(try playableFrameCount(fixture.audioURL) == 16_000)
        #expect(fixture.store.entries().isEmpty)

        // A later launch does not recover it a second time.
        #expect(fixture.recovery().recoverInterruptedRecordings().isEmpty)
        #expect(try allTranscriptions(fixture.context).count == 1)
    }

    @Test func aRecordingStillOwnedByARunningProcessIsLeftAlone() throws {
        let fixture = try makeFixture(frames: 16_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let recovered = fixture.recovery(isRecordingOwnerRunning: { $0.processID == exitedProcessID }).recoverInterruptedRecordings()

        #expect(recovered.isEmpty)
        #expect(fixture.store.entries().count == 1)
        #expect(try allTranscriptions(fixture.context).isEmpty)
    }

    @Test func aMarkerAlreadyInHistoryIsClearedWithoutADuplicate() throws {
        let fixture = try makeFixture(frames: 16_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.context.insert(
            Transcription(text: "", duration: 0, audioFileURL: fixture.audioURL.absoluteString)
        )
        try fixture.context.save()

        #expect(fixture.recovery().recoverInterruptedRecordings().isEmpty)
        #expect(try allTranscriptions(fixture.context).count == 1)
        #expect(fixture.store.entries().isEmpty)
    }

    @Test func markersWithoutUsableAudioAreClearedAndEmptyAudioIsDeleted() throws {
        let missing = try makeFixture(frames: nil)
        defer { try? FileManager.default.removeItem(at: missing.directory) }
        #expect(missing.recovery().recoverInterruptedRecordings().isEmpty)
        #expect(missing.store.entries().isEmpty)

        let empty = try makeFixture(frames: 0)
        defer { try? FileManager.default.removeItem(at: empty.directory) }
        #expect(empty.recovery().recoverInterruptedRecordings().isEmpty)
        #expect(empty.store.entries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: empty.audioURL.path))
        #expect(try allTranscriptions(empty.context).isEmpty)
    }

    @Test func transcribingARecoveredRecordingUpdatesTheSameHistoryEntry() async throws {
        let fixture = try makeFixture(frames: 16_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.context.insert(WordReplacement(originalText: "voice ink", replacementText: "VoiceInk"))
        try fixture.context.save()
        let recovered = try #require(fixture.recovery().recoverInterruptedRecordings().first)
        let transcriber = RecordingTranscriber(output: "  saved by voice ink  ")
        let service = AudioTranscriptionService(
            modelContext: fixture.context,
            transcriber: transcriber,
            enhancementService: nil
        )

        let result = try await service.retranscribeAudio(
            from: fixture.audioURL,
            using: RecoveryTestModel(),
            mode: ModeConfig(name: "Notes", isAIEnhancementEnabled: false),
            updating: recovered
        )

        #expect(result.transcription.id == recovered.id)
        #expect(transcriber.receivedURLs == [fixture.audioURL])
        let entries = try allTranscriptions(fixture.context)
        #expect(entries.map(\.id) == [recovered.id])
        #expect(recovered.text == "saved by VoiceInk")
        #expect(recovered.transcriptionStatus == TranscriptionStatus.completed.rawValue)
        #expect(!recovered.isRecoveredRecording)
        #expect(recovered.modeName == "Notes")
        #expect(recovered.transcriptionModelName == "Recovery Model")
        #expect(recovered.audioFileURL == fixture.audioURL.absoluteString)
        #expect(abs(recovered.duration - 1.0) < 0.01)
    }

    @Test func discardingARecoveredRecordingRemovesTheEntryAndItsAudio() throws {
        let fixture = try makeFixture(frames: 16_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recovered = try #require(fixture.recovery().recoverInterruptedRecordings().first)

        try InterruptedRecordingRecovery.discard(recovered, in: fixture.context)

        #expect(try allTranscriptions(fixture.context).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }
}
