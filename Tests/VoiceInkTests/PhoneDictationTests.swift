import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import VoiceInk

// MARK: - Fakes

private struct FakeTranscriptionModel: TranscriptionModel {
    let id = UUID()
    let name = "fake-model"
    let displayName = "Fake Model"
    let description = "Test model"
    let provider: ModelProvider = .groq
    let isMultilingualModel = false
    let supportedLanguages: [String: String] = ["en": "English"]
}

@MainActor
private final class FakeTranscriber: AudioFileTranscriber {
    var output: String
    var error: Error?
    private(set) var receivedURLs: [URL] = []
    private(set) var receivedContexts: [TranscriptionRequestContext] = []
    private(set) var cleanupCount = 0

    init(output: String, error: Error? = nil) {
        self.output = output
        self.error = error
    }

    func transcribe(
        audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> String {
        receivedURLs.append(audioURL)
        receivedContexts.append(context)
        if let error { throw error }
        return output
    }

    func cleanup() async {
        cleanupCount += 1
    }
}

private final class InMemoryTokenStorage: PhoneDictationTokenStorage {
    var token: String?
    var failsWrites = false

    func readToken() -> String? { token }

    func writeToken(_ token: String) -> Bool {
        guard !failsWrites else { return false }
        self.token = token
        return true
    }
}

private struct TestFailure: Error, LocalizedError {
    var errorDescription: String? { "model exploded" }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PhoneDictationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a one-second 440 Hz tone, encoded as AAC in an m4a container like an Android recorder.
private func makeM4ARecording(in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("recording.m4a")
    let sampleRate = 44_100.0
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let format = file.processingFormat
    let frames = AVAudioFrameCount(sampleRate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let channel = try #require(buffer.floatChannelData?[0])
    for frame in 0..<Int(frames) {
        channel[frame] = Float(sin(2 * .pi * 440 * Double(frame) / sampleRate)) * 0.3
    }
    try file.write(from: buffer)
    return url
}

// MARK: - Shared pipeline

@MainActor
@Suite(.serialized)
struct AudioFileTranscriptionPipelineTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Transcription.self, VocabularyWord.self, WordReplacement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func pipeline(
        context: ModelContext,
        transcriber: FakeTranscriber,
        recordings: URL,
        hasModel: Bool = true
    ) -> AudioFileTranscriptionPipeline {
        AudioFileTranscriptionPipeline(
            modelContext: context,
            dependencies: .init(
                resolveConfiguration: { mode in
                    guard hasModel else { return nil }
                    return TranscriptionRuntimeConfiguration(
                        mode: mode, model: FakeTranscriptionModel(), language: "en", isRealtimeEnabled: false)
                },
                makeTranscriber: { transcriber },
                enhancementService: nil,
                recordingsDirectory: recordings
            )
        )
    }

    @Test func phoneRecordingGoesThroughDictionaryAndReplacementsAndIsSavedAsFromPhone() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordings = directory.appendingPathComponent("Recordings")
        let context = try makeContext()
        context.insert(WordReplacement(originalText: "voice ink", replacementText: "VoiceInk"))
        context.insert(VocabularyWord(word: "Tailscale"))
        try context.save()

        let transcriber = FakeTranscriber(output: "  hello from voice ink  ")
        let mode = ModeConfig(name: "Phone", isAIEnhancementEnabled: false)
        var phases: [AudioFileTranscriptionPipeline.Phase] = []

        let result = try await pipeline(context: context, transcriber: transcriber, recordings: recordings)
            .transcribe(
                audioURL: try makeM4ARecording(in: directory), mode: mode, source: .phone
            ) { phases.append($0) }

        #expect(result.finalText == "hello from VoiceInk")
        #expect(result.enhancementFailure == nil)
        #expect(phases == [.loading, .processingAudio, .transcribing])
        #expect(transcriber.cleanupCount == 1)

        let sentURL = try #require(transcriber.receivedURLs.first)
        #expect(sentURL.deletingLastPathComponent().standardizedFileURL == recordings.standardizedFileURL)
        #expect(sentURL.pathExtension == "wav")
        #expect(FileManager.default.fileExists(atPath: sentURL.path))
        #expect(transcriber.receivedContexts.first?.vocabulary?.terms == ["Tailscale"])

        let saved = try context.fetch(FetchDescriptor<Transcription>())
        #expect(saved.count == 1)
        let entry = try #require(saved.first)
        #expect(entry.id == result.transcription.id)
        #expect(entry.text == "hello from VoiceInk")
        #expect(entry.transcriptionSource == .phone)
        #expect(entry.modeName == "Phone")
        #expect(entry.transcriptionModelName == "Fake Model")
        #expect(entry.audioFileURL == sentURL.absoluteString)
        #expect(abs(entry.duration - 1) < 0.2)
    }

    @Test func importsWithoutASourceStayMarkedAsFromTheMac() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try makeContext()
        let transcriber = FakeTranscriber(output: "imported")

        let result = try await pipeline(
            context: context, transcriber: transcriber, recordings: directory.appendingPathComponent("R")
        ).transcribe(audioURL: try makeM4ARecording(in: directory), mode: ModeConfig(name: "M", isAIEnhancementEnabled: false))

        #expect(result.transcription.source == nil)
        #expect(result.transcription.transcriptionSource == nil)
    }

    @Test func noUsableModelFailsBeforeAnyPhaseAndStillCleansUp() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try makeContext()
        let transcriber = FakeTranscriber(output: "unused")
        var phases: [AudioFileTranscriptionPipeline.Phase] = []

        await #expect(throws: TranscriptionError.self) {
            _ = try await pipeline(
                context: context, transcriber: transcriber, recordings: directory, hasModel: false
            ).transcribe(
                audioURL: try makeM4ARecording(in: directory),
                mode: ModeConfig(name: "M", isAIEnhancementEnabled: false)
            ) { phases.append($0) }
        }
        #expect(phases.isEmpty)
        #expect(transcriber.receivedURLs.isEmpty)
        #expect(transcriber.cleanupCount == 1)
        #expect(try context.fetch(FetchDescriptor<Transcription>()).isEmpty)
    }

    @Test func transcriberFailurePropagatesWithoutSavingHistory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try makeContext()
        let transcriber = FakeTranscriber(output: "", error: TestFailure())

        await #expect(throws: TestFailure.self) {
            _ = try await pipeline(context: context, transcriber: transcriber, recordings: directory)
                .transcribe(
                    audioURL: try makeM4ARecording(in: directory),
                    mode: ModeConfig(name: "M", isAIEnhancementEnabled: false))
        }
        #expect(transcriber.cleanupCount == 1)
        #expect(try context.fetch(FetchDescriptor<Transcription>()).isEmpty)
    }
}

// MARK: - Token store

struct PhoneDictationTokenStoreTests {
    @Test func tokenIsCreatedOnceAndPersisted() throws {
        let storage = InMemoryTokenStorage()
        let store = PhoneDictationTokenStore(storage: storage)

        let token = try store.currentToken()
        #expect(token.count >= 43)
        #expect(storage.token == token)
        #expect(try store.currentToken() == token)
        #expect(try PhoneDictationTokenStore(storage: storage).currentToken() == token)
    }

    @Test func regeneratingInvalidatesTheOldToken() throws {
        let store = PhoneDictationTokenStore(storage: InMemoryTokenStorage())
        let old = try store.currentToken()

        let new = try store.regenerate()

        #expect(new != old)
        #expect(!store.isValid(old))
        #expect(store.isValid(new))
    }

    @Test func failedKeychainWriteKeepsTheCurrentToken() throws {
        let storage = InMemoryTokenStorage()
        let store = PhoneDictationTokenStore(storage: storage)
        let token = try store.currentToken()
        storage.failsWrites = true

        #expect(throws: PhoneDictationTokenError.self) { try store.regenerate() }
        #expect(store.isValid(token))
    }

    @Test func missingOrWrongTokensAreInvalid() throws {
        let store = PhoneDictationTokenStore(storage: InMemoryTokenStorage())
        #expect(!store.isValid("anything"))
        let token = try store.currentToken()
        #expect(!store.isValid(nil))
        #expect(!store.isValid(""))
        #expect(!store.isValid(String(token.dropLast()) + "x"))
    }
}

// MARK: - Addresses

struct PhoneDictationAddressTests {
    @Test func classifiesTailscaleAndLANAddresses() {
        #expect(PhoneDictationAddresses.kind(forIPv4: "100.101.102.103") == .tailscale)
        #expect(PhoneDictationAddresses.kind(forIPv4: "100.64.0.1") == .tailscale)
        #expect(PhoneDictationAddresses.kind(forIPv4: "100.128.0.1") == .lan)
        #expect(PhoneDictationAddresses.kind(forIPv4: "192.168.1.20") == .lan)
        #expect(PhoneDictationAddresses.kind(forIPv4: "10.0.0.5") == .lan)
        #expect(PhoneDictationAddresses.kind(forIPv4: "127.0.0.1") == nil)
        #expect(PhoneDictationAddresses.kind(forIPv4: "169.254.3.4") == nil)
        #expect(PhoneDictationAddresses.kind(forIPv4: "not-an-ip") == nil)
    }
}

// MARK: - Server and API

@MainActor
private final class ServerProbe {
    var readiness: PhoneDictationReadiness = .ready(model: "Fake Model", mode: "Phone")
    var transcribeError: Error?
    var transcribeDelay: Duration = .zero
    private(set) var uploads: [(ext: String, data: Data)] = []
    private(set) var active = 0
    private(set) var maxActive = 0

    func transcribe(_ url: URL) async throws -> PhoneDictationTranscribeBody {
        active += 1
        maxActive = max(maxActive, active)
        defer { active -= 1 }
        uploads.append((url.pathExtension, try Data(contentsOf: url)))
        if transcribeDelay != .zero {
            try await Task.sleep(for: transcribeDelay)
        }
        if let transcribeError { throw transcribeError }
        return PhoneDictationTranscribeBody(
            id: UUID(), text: "text \(uploads.count)", durationSeconds: 1, model: "Fake Model", mode: "Phone",
            enhancementError: nil)
    }
}

@MainActor
@Suite(.serialized)
struct PhoneDictationServerTests {
    private struct Harness {
        let server: PhoneDictationServer
        let tokenStore: PhoneDictationTokenStore
        let probe: ServerProbe
        let port: UInt16
        let token: String

        func request(
            _ path: String, method: String = "GET", token: String?, body: Data? = nil,
            contentType: String? = "audio/mp4", extraHeaders: [String: String] = [:]
        ) async throws -> (status: Int, data: Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.timeoutInterval = 10
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
            if let body {
                request.httpBody = body
                if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, data)
        }
    }

    private func start(
        maxBodyBytes: Int = 4096,
        tokenStore: PhoneDictationTokenStore? = nil,
        probe: ServerProbe? = nil,
        queue: PhoneDictationSerialQueue = PhoneDictationSerialQueue()
    ) async throws -> Harness {
        let tokenStore = tokenStore ?? PhoneDictationTokenStore(storage: InMemoryTokenStorage())
        let token = try tokenStore.currentToken()
        let probe = probe ?? ServerProbe()
        let server = PhoneDictationServer(
            tokenStore: tokenStore,
            handlers: PhoneDictationHandlers(
                readiness: { probe.readiness },
                transcribe: { try await probe.transcribe($0) }
            ),
            maxBodyBytes: maxBodyBytes,
            queue: queue
        )
        let port = try await server.start(port: 0)
        return Harness(server: server, tokenStore: tokenStore, probe: probe, port: port, token: token)
    }

    private func errorCode(_ data: Data) throws -> PhoneDictationErrorCode {
        try JSONDecoder().decode(PhoneDictationErrorBody.self, from: data).error.code
    }

    @Test func statusReportsReadinessOnlyToAPairedPhone() async throws {
        let harness = try await start()
        defer { harness.server.stop() }

        let ready = try await harness.request("/v1/status", token: harness.token)
        #expect(ready.status == 200)
        let body = try JSONDecoder().decode(PhoneDictationStatusBody.self, from: ready.data)
        #expect(body == PhoneDictationStatusBody(apiVersion: 1, status: "ready", model: "Fake Model", mode: "Phone"))

        let missing = try await harness.request("/v1/status", token: nil)
        #expect(missing.status == 401)
        #expect(try errorCode(missing.data) == .unauthorized)

        let wrong = try await harness.request("/v1/status", token: "wrong")
        #expect(wrong.status == 401)

        harness.probe.readiness = .noModelSelected
        let notReady = try await harness.request("/v1/status", token: harness.token)
        #expect(notReady.status == 503)
        #expect(try errorCode(notReady.data) == .noModelSelected)
    }

    @Test func transcribeReturnsTheFinalTextForAnM4AUpload() async throws {
        let harness = try await start()
        defer { harness.server.stop() }
        let audio = Data((0..<2000).map { UInt8($0 % 251) })

        let response = try await harness.request(
            "/v1/transcribe", method: "POST", token: harness.token, body: audio, contentType: "audio/mp4")

        #expect(response.status == 200)
        let body = try JSONDecoder().decode(PhoneDictationTranscribeBody.self, from: response.data)
        #expect(body.text == "text 1")
        #expect(harness.probe.uploads.count == 1)
        #expect(harness.probe.uploads.first?.ext == "m4a")
        #expect(harness.probe.uploads.first?.data == audio)
    }

    @Test func formatQueryChoosesTheExtensionForGenericUploads() async throws {
        let harness = try await start()
        defer { harness.server.stop() }

        let wav = try await harness.request(
            "/v1/transcribe?format=wav", method: "POST", token: harness.token, body: Data([1, 2, 3]),
            contentType: "application/octet-stream")
        #expect(wav.status == 200)
        #expect(harness.probe.uploads.last?.ext == "wav")

        let unknown = try await harness.request(
            "/v1/transcribe", method: "POST", token: harness.token, body: Data([1, 2, 3]),
            contentType: "application/octet-stream")
        #expect(unknown.status == 415)
        #expect(try errorCode(unknown.data) == .unsupportedMediaType)
    }

    @Test func unauthorizedUploadsNeverReachThePipeline() async throws {
        let harness = try await start()
        defer { harness.server.stop() }

        for token in [nil, "wrong"] as [String?] {
            let response = try await harness.request(
                "/v1/transcribe", method: "POST", token: token, body: Data([1, 2, 3]))
            #expect(response.status == 401)
            #expect(try errorCode(response.data) == .unauthorized)
        }
        #expect(harness.probe.uploads.isEmpty)
    }

    @Test func regeneratedTokenImmediatelyInvalidatesTheOldOne() async throws {
        let harness = try await start()
        defer { harness.server.stop() }

        let newToken = try harness.tokenStore.regenerate()

        let old = try await harness.request(
            "/v1/transcribe", method: "POST", token: harness.token, body: Data([1, 2, 3]))
        #expect(old.status == 401)
        #expect(harness.probe.uploads.isEmpty)
        let new = try await harness.request("/v1/status", token: newToken)
        #expect(new.status == 200)
    }

    @Test func pipelineOutcomesMapToStructuredErrors() async throws {
        let harness = try await start()
        defer { harness.server.stop() }

        harness.probe.readiness = .noModelSelected
        let notReady = try await harness.request(
            "/v1/transcribe", method: "POST", token: harness.token, body: Data([1]))
        #expect(notReady.status == 503)
        #expect(try errorCode(notReady.data) == .noModelSelected)
        #expect(harness.probe.uploads.isEmpty)

        harness.probe.readiness = .ready(model: "Fake Model", mode: nil)
        harness.probe.transcribeError = TranscriptionError.noModelSelected
        let raced = try await harness.request(
            "/v1/transcribe", method: "POST", token: harness.token, body: Data([1]))
        #expect(raced.status == 503)
        #expect(try errorCode(raced.data) == .noModelSelected)

        harness.probe.transcribeError = TestFailure()
        let failed = try await harness.request(
            "/v1/transcribe", method: "POST", token: harness.token, body: Data([1]))
        #expect(failed.status == 500)
        let failure = try JSONDecoder().decode(PhoneDictationErrorBody.self, from: failed.data)
        #expect(failure.error.code == .transcriptionFailed)
        #expect(failure.error.message == "model exploded")
    }

    @Test func requestSizeIsBounded() async throws {
        let harness = try await start(maxBodyBytes: 1024)
        defer { harness.server.stop() }

        let response = try await harness.request(
            "/v1/transcribe", method: "POST", token: harness.token, body: Data(count: 2048))

        #expect(response.status == 413)
        #expect(try errorCode(response.data) == .payloadTooLarge)
        #expect(harness.probe.uploads.isEmpty)
    }

    @Test func unknownEndpointsAndMethodsAreRejected() async throws {
        let harness = try await start()
        defer { harness.server.stop() }

        let unknown = try await harness.request("/v2/transcribe", token: harness.token)
        #expect(unknown.status == 404)
        #expect(try errorCode(unknown.data) == .notFound)

        let wrongMethod = try await harness.request("/v1/transcribe", method: "GET", token: harness.token)
        #expect(wrongMethod.status == 405)
        #expect(try errorCode(wrongMethod.data) == .methodNotAllowed)
    }

    @Test func concurrentUploadsAreProcessedOneAtATime() async throws {
        let harness = try await start()
        defer { harness.server.stop() }
        harness.probe.transcribeDelay = .milliseconds(150)

        let statuses = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<3 {
                group.addTask {
                    try await harness.request(
                        "/v1/transcribe", method: "POST", token: harness.token, body: Data([UInt8(index)])
                    ).status
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(statuses == [200, 200, 200])
        #expect(harness.probe.uploads.count == 3)
        #expect(harness.probe.maxActive == 1)
    }

    @Test func turningTheServerOffAndOnNeverOverlapsTranscriptions() async throws {
        let queue = PhoneDictationSerialQueue()
        let first = try await start(queue: queue)
        let probe = first.probe
        probe.transcribeDelay = .milliseconds(400)

        // One request transcribing and one queued behind it when the server is turned off.
        let running = Task { try? await first.request("/v1/transcribe", method: "POST", token: first.token, body: Data([1])) }
        try await Task.sleep(for: .milliseconds(100))
        let queued = Task { try? await first.request("/v1/transcribe", method: "POST", token: first.token, body: Data([2])) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.active == 1)
        first.server.stop()

        let second = try await start(tokenStore: first.tokenStore, probe: probe, queue: queue)
        defer { second.server.stop() }
        let afterRestart = try await second.request(
            "/v1/transcribe", method: "POST", token: second.token, body: Data([3]))
        _ = await running.value
        _ = await queued.value

        #expect(afterRestart.status == 200)
        #expect(probe.maxActive == 1)
        #expect(probe.uploads.map(\.data) == [Data([1]), Data([3])])
    }

    @Test func oversizedHeadersAreRejected() async throws {
        let harness = try await start()
        defer { harness.server.stop() }

        let response = try await harness.request(
            "/v1/status", token: harness.token,
            extraHeaders: ["X-Padding": String(repeating: "a", count: PhoneDictationAPI.maxHeadBytes + 1)])

        #expect(response.status == 400)
        #expect(try errorCode(response.data) == .badRequest)
    }

    @Test func stoppingReleasesThePortAndRestartingReusesIt() async throws {
        let harness = try await start()
        #expect(try await harness.request("/v1/status", token: harness.token).status == 200)

        harness.server.stop()
        #expect(!harness.server.isRunning)
        var refused = false
        for _ in 0..<20 where !refused {
            do {
                _ = try await harness.request("/v1/status", token: harness.token)
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                refused = true
            }
        }
        #expect(refused)

        let restarted = try await harness.server.start(port: harness.port)
        defer { harness.server.stop() }
        #expect(restarted == harness.port)
        #expect(try await harness.request("/v1/status", token: harness.token).status == 200)
    }
}

// MARK: - Request heads

struct PhoneDictationRouterTests {
    private func head(_ raw: String) throws -> PhoneDictationHTTPRequestHead {
        try #require(PhoneDictationHTTPRequestHead.parse(Data(raw.utf8)))
    }

    private func router(token: String) -> PhoneDictationRouter {
        let storage = InMemoryTokenStorage()
        storage.token = token
        return PhoneDictationRouter(
            tokenStore: PhoneDictationTokenStore(storage: storage),
            handlers: PhoneDictationHandlers(
                readiness: { .noModelSelected },
                transcribe: { _ in throw TestFailure() }
            ),
            maxBodyBytes: 100
        )
    }

    @Test func uploadsWithoutADeclaredLengthAreRejectedBeforeTheBody() throws {
        let router = router(token: "secret")

        let chunked = try head(
            "POST /v1/transcribe HTTP/1.1\r\nAuthorization: Bearer secret\r\nContent-Type: audio/mp4\r\nTransfer-Encoding: chunked"
        )
        #expect(router.decide(chunked) == .respond(.error(.lengthRequired)))

        let noLength = try head(
            "POST /v1/transcribe HTTP/1.1\r\nAuthorization: Bearer secret\r\nContent-Type: audio/mp4")
        #expect(router.decide(noLength) == .respond(.error(.lengthRequired)))

        let accepted = try head(
            "POST /v1/transcribe HTTP/1.1\r\nauthorization: bearer secret\r\ncontent-type: audio/wav\r\ncontent-length: 10"
        )
        #expect(router.decide(accepted) == .readBody(length: 10, fileExtension: "wav"))
    }

    @Test func anUnsupportedExplicitFormatIsRejectedEvenWithAKnownContentType() throws {
        let router = router(token: "secret")
        let request = try head(
            "POST /v1/transcribe?format=xyz HTTP/1.1\r\nAuthorization: Bearer secret\r\nContent-Type: audio/wav\r\nContent-Length: 10"
        )
        #expect(router.decide(request) == .respond(.error(.unsupportedMediaType)))
    }

    @Test func malformedRequestLinesAreNotParsed() {
        #expect(PhoneDictationHTTPRequestHead.parse(Data("garbage".utf8)) == nil)
        #expect(PhoneDictationHTTPRequestHead.parse(Data("GET /v1/status SPDY/3\r\n".utf8)) == nil)
    }
}
