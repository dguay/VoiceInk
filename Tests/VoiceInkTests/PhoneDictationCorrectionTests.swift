import Foundation
import SwiftData
import Testing
@testable import VoiceInk

private final class CorrectionTokenStorage: PhoneDictationTokenStorage {
    var token: String?

    func readToken() -> String? { token }

    func writeToken(_ token: String) -> Bool {
        self.token = token
        return true
    }
}

private func correctionTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PhoneDictationCorrectionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// "Dictate Parakeat" typed into an empty field, then corrected to "Parakeet".
private func parakeetRequest(id: UUID = UUID()) -> PhoneDictationCorrectionRequest {
    PhoneDictationCorrectionRequest(
        id: id,
        insertedText: "Dictate with Parakeat today",
        textAfterInsert: "Note: Dictate with Parakeat today",
        textWhenLeft: "Note: Dictate with Parakeet today",
        insertStart: 6
    )
}

private func encoded(_ request: PhoneDictationCorrectionRequest) throws -> Data {
    try JSONEncoder().encode(request)
}

// MARK: - Request validation

struct PhoneDictationCorrectionRequestTests {
    private func problem(_ request: PhoneDictationCorrectionRequest) throws -> String? {
        switch PhoneDictationCorrectionRequest.decode(try encoded(request)) {
        case .success: return nil
        case .failure(let error): return error.message
        }
    }

    @Test func aWellFormedSnapshotBecomesTheSameFieldSnapshotAMacPasteProduces() throws {
        let request = parakeetRequest()
        let decoded = try PhoneDictationCorrectionRequest.decode(encoded(request)).get()
        #expect(decoded == request)

        let snapshot = decoded.fieldSnapshot
        #expect(snapshot.baselineFieldText == request.textAfterInsert)
        #expect(snapshot.finalFieldText == request.textWhenLeft)
        #expect(snapshot.pastedRange == NSRange(location: 6, length: 27))
        #expect(snapshot.originalPastedText == request.insertedText)
        let revision = try #require(FinalSnapshotDiffEngine.revision(from: snapshot))
        #expect(revision.original == "Dictate with Parakeat today")
        #expect(revision.corrected == "Dictate with Parakeet today")
    }

    @Test func malformedBodiesAndInconsistentFieldsAreRejected() throws {
        #expect(throws: (any Error).self) { try PhoneDictationCorrectionRequest.decode(Data("nope".utf8)).get() }
        #expect(throws: (any Error).self) {
            try PhoneDictationCorrectionRequest.decode(Data(#"{"id":"not-a-uuid","insertedText":"a"}"#.utf8)).get()
        }

        let base = parakeetRequest()
        func with(inserted: String? = nil, after: String? = nil, left: String? = nil, start: Int? = nil)
            -> PhoneDictationCorrectionRequest
        {
            PhoneDictationCorrectionRequest(
                id: base.id, insertedText: inserted ?? base.insertedText,
                textAfterInsert: after ?? base.textAfterInsert, textWhenLeft: left ?? base.textWhenLeft,
                insertStart: start ?? base.insertStart)
        }
        #expect(try problem(with(inserted: "")) != nil)
        #expect(try problem(with(start: -1)) != nil)
        #expect(try problem(with(start: 7)) != nil)  // Range runs past the end.
        #expect(try problem(with(start: 0)) != nil)  // Does not match the text at that position.
        let tooLong = String(repeating: "a", count: PhoneDictationAPI.maxCorrectionTextLength + 1)
        #expect(try problem(with(left: tooLong)) != nil)
        #expect(try problem(base) == nil)
    }
}

// MARK: - Head decisions

struct PhoneDictationCorrectionRouterTests {
    private func head(_ raw: String) throws -> PhoneDictationHTTPRequestHead {
        try #require(PhoneDictationHTTPRequestHead.parse(Data(raw.utf8)))
    }

    private func router() -> PhoneDictationRouter {
        let storage = CorrectionTokenStorage()
        storage.token = "secret"
        return PhoneDictationRouter(
            tokenStore: PhoneDictationTokenStore(storage: storage),
            handlers: PhoneDictationHandlers(readiness: { .noModelSelected }, transcribe: { _ in throw CancellationError() }),
            maxBodyBytes: 100
        )
    }

    @Test func unauthorizedAndOversizedCorrectionsAreRejectedBeforeTheBody() throws {
        let router = router()

        let noToken = try head("POST /v1/corrections HTTP/1.1\r\nContent-Length: 10")
        #expect(router.decide(noToken) == .respond(.error(.unauthorized)))
        let wrongToken = try head("POST /v1/corrections HTTP/1.1\r\nAuthorization: Bearer nope\r\nContent-Length: 10")
        #expect(router.decide(wrongToken) == .respond(.error(.unauthorized)))

        let tooLarge = try head(
            "POST /v1/corrections HTTP/1.1\r\nAuthorization: Bearer secret\r\nContent-Length: \(PhoneDictationAPI.maxCorrectionBodyBytes + 1)"
        )
        guard case .respond(let response) = router.decide(tooLarge) else {
            Issue.record("An oversized correction must be answered on the head")
            return
        }
        #expect(response.status == 413)
        let error = try JSONDecoder().decode(PhoneDictationErrorBody.self, from: response.body)
        #expect(error.error.code == .payloadTooLarge)

        let noLength = try head("POST /v1/corrections HTTP/1.1\r\nAuthorization: Bearer secret")
        #expect(router.decide(noLength) == .respond(.error(.lengthRequired)))
        let chunked = try head(
            "POST /v1/corrections HTTP/1.1\r\nAuthorization: Bearer secret\r\nTransfer-Encoding: chunked")
        #expect(router.decide(chunked) == .respond(.error(.lengthRequired)))
        let get = try head("GET /v1/corrections HTTP/1.1\r\nAuthorization: Bearer secret")
        #expect(router.decide(get) == .respond(.error(.methodNotAllowed)))
    }

    @Test func aCorrectionWithinTheLimitIsRead() throws {
        // The audio limit (100 bytes here) does not apply; the correction has its own.
        let accepted = try head("POST /v1/corrections HTTP/1.1\r\nAuthorization: Bearer secret\r\nContent-Length: 2000")
        #expect(router().decide(accepted) == .readBody(length: 2000, fileExtension: "json"))
    }
}

// MARK: - Over HTTP

@MainActor
private final class CorrectionProbe {
    var outcome: PhoneDictationCorrectionOutcome = .accepted(autoLearnEnabled: true)
    private(set) var received: [PhoneDictationCorrectionRequest] = []

    func submit(_ request: PhoneDictationCorrectionRequest) -> PhoneDictationCorrectionOutcome {
        received.append(request)
        return outcome
    }
}

@MainActor
@Suite(.serialized)
struct PhoneDictationCorrectionServerTests {
    private struct Harness {
        let server: PhoneDictationServer
        let probe: CorrectionProbe
        let port: UInt16
        let token: String

        func post(_ body: Data, token: String?) async throws -> (status: Int, data: Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/corrections")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, data)
        }
    }

    private func start() async throws -> Harness {
        let tokenStore = PhoneDictationTokenStore(storage: CorrectionTokenStorage())
        let token = try tokenStore.currentToken()
        let probe = CorrectionProbe()
        var handlers = PhoneDictationHandlers(
            readiness: { .ready(model: "Fake Model", mode: nil) },
            transcribe: { _ in throw CancellationError() }
        )
        handlers.submitCorrection = { probe.submit($0) }
        let server = PhoneDictationServer(tokenStore: tokenStore, handlers: handlers, maxBodyBytes: 16)
        let port = try await server.start(port: 0)
        return Harness(server: server, probe: probe, port: port, token: token)
    }

    private func errorCode(_ data: Data) throws -> PhoneDictationErrorCode {
        try JSONDecoder().decode(PhoneDictationErrorBody.self, from: data).error.code
    }

    @Test func anAcceptedCorrectionReportsWhetherAutoLearnIsOn() async throws {
        let harness = try await start()
        defer { harness.server.stop() }
        let request = parakeetRequest()

        let on = try await harness.post(encoded(request), token: harness.token)
        #expect(on.status == 200)
        #expect(try JSONDecoder().decode(PhoneDictationCorrectionBody.self, from: on.data)
            == PhoneDictationCorrectionBody(status: "accepted", autoLearnEnabled: true))
        #expect(harness.probe.received == [request])

        harness.probe.outcome = .accepted(autoLearnEnabled: false)
        let off = try await harness.post(encoded(request), token: harness.token)
        #expect(off.status == 200)
        #expect(try JSONDecoder().decode(PhoneDictationCorrectionBody.self, from: off.data).autoLearnEnabled == false)
    }

    @Test func unknownAndNonPhoneDictationsAreRejected() async throws {
        let harness = try await start()
        defer { harness.server.stop() }

        harness.probe.outcome = .unknownDictation
        let unknown = try await harness.post(encoded(parakeetRequest()), token: harness.token)
        #expect(unknown.status == 404)
        #expect(try errorCode(unknown.data) == .unknownDictation)

        harness.probe.outcome = .notPhoneDictation
        let mac = try await harness.post(encoded(parakeetRequest()), token: harness.token)
        #expect(mac.status == 409)
        #expect(try errorCode(mac.data) == .notPhoneDictation)
    }

    @Test func badTokensAndMalformedBodiesNeverReachAutoLearn() async throws {
        let harness = try await start()
        defer { harness.server.stop() }

        for token in [nil, "wrong"] as [String?] {
            let response = try await harness.post(encoded(parakeetRequest()), token: token)
            #expect(response.status == 401)
            #expect(try errorCode(response.data) == .unauthorized)
        }
        let malformed = try await harness.post(Data(#"{"id": 3}"#.utf8), token: harness.token)
        #expect(malformed.status == 400)
        #expect(try errorCode(malformed.data) == .badRequest)

        var inconsistent = try JSONSerialization.jsonObject(with: encoded(parakeetRequest())) as! [String: Any]
        inconsistent["insertStart"] = 0
        let mismatch = try await harness.post(JSONSerialization.data(withJSONObject: inconsistent), token: harness.token)
        #expect(mismatch.status == 400)
        #expect(harness.probe.received.isEmpty)
    }
}

// MARK: - History lookup

@MainActor
@Suite(.serialized)
struct PhoneDictationCorrectionIntakeTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Transcription.self, VocabularyWord.self, WordReplacement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func onlyPhoneDictationsInHistoryReachAutoLearnAndEachOnlyOnce() async throws {
        let context = try makeContext()
        let phone = Transcription(text: "Dictate with Parakeat today", duration: 1, source: .phone)
        let mac = Transcription(text: "Dictate with Parakeat today", duration: 1)
        context.insert(phone)
        context.insert(mac)
        try context.save()

        var learned: [AutoLearnFieldSnapshot] = []
        let intake = PhoneDictationCorrectionIntake(modelContext: context) { snapshot in
            learned.append(snapshot)
            return true
        }

        #expect(await intake.submit(parakeetRequest(id: UUID())) == .unknownDictation)
        #expect(await intake.submit(parakeetRequest(id: mac.id)) == .notPhoneDictation)
        #expect(learned.isEmpty)

        #expect(await intake.submit(parakeetRequest(id: phone.id)) == .accepted(autoLearnEnabled: true))
        #expect(learned.count == 1)
        #expect(learned.first?.originalPastedText == "Dictate with Parakeat today")

        // A retry after a lost response is accepted but not learned twice.
        _ = await intake.submit(parakeetRequest(id: phone.id))
        #expect(learned.count == 1)
    }
}

// MARK: - Auto-Learn

@Suite(.serialized)
struct AutoLearnPhoneSnapshotTests {
    private struct Fixture {
        let service: AutoLearnService
        let queue: AutoLearnPendingQueue
        let defaults: UserDefaults
        let directory: URL
        let suiteName: String

        func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func fixture(autoLearnEnabled: Bool) throws -> Fixture {
        let directory = try correctionTemporaryDirectory()
        let suiteName = "AutoLearnPhoneSnapshotTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(autoLearnEnabled, forKey: AutoLearnSettings.isEnabledKey)
        let queue = AutoLearnPendingQueue(
            fileURL: directory.appendingPathComponent("pending.json"),
            archiveFileURL: directory.appendingPathComponent("archive.json"))
        let proposals = AutoLearnReviewProposalStore(
            fileURL: directory.appendingPathComponent("proposals.json"),
            dismissedPairsFileURL: directory.appendingPathComponent("dismissed.json"))
        let service = AutoLearnService(defaults: defaults, pendingQueue: queue, reviewProposalStore: proposals)
        return Fixture(service: service, queue: queue, defaults: defaults, directory: directory, suiteName: suiteName)
    }

    @Test func aPhoneCorrectionQueuesAnAutoLearnCandidateWhenAutoLearnIsOn() async throws {
        let fixture = try fixture(autoLearnEnabled: true)
        defer { fixture.tearDown() }

        let learned = await fixture.service.learnFromExternalSnapshot(parakeetRequest().fieldSnapshot)

        #expect(learned)
        #expect(try await fixture.queue.pendingCount() == 1)
        let candidates = try await fixture.queue.claimAllPending()
        #expect(candidates.contains { $0.originalText.contains("Parakeat") && $0.correctedText.contains("Parakeet") })
    }

    @Test func nothingIsQueuedWhenAutoLearnIsOff() async throws {
        let fixture = try fixture(autoLearnEnabled: false)
        defer { fixture.tearDown() }

        let learned = await fixture.service.learnFromExternalSnapshot(parakeetRequest().fieldSnapshot)

        #expect(!learned)
        #expect(try await fixture.queue.outstandingCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("pending.json").path))
    }
}
