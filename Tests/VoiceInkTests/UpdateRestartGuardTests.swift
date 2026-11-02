import Combine
import Foundation
import Testing
@testable import VoiceInk

@MainActor
struct UpdateRestartGuardTests {
    private let candidate = StagedForkCandidate(
        forkCommit: "0123456789abcdef0123456789abcdef01234567",
        upstreamCommit: "fedcba9876543210fedcba9876543210fedcba98",
        bundleURL: URL(fileURLWithPath: "/tmp/VoiceInk.app"),
        preparedAt: Date(timeIntervalSince1970: 1_787_400_000)
    )

    @Test
    func onlyAnIdleEngineAllowsARestart() {
        #expect(UpdateRestartGuard.blockingReason(for: .idle) == nil)
        for busyState in [RecordingState.starting, .recording, .transcribing, .enhancing, .busy] {
            #expect(UpdateRestartGuard.blockingReason(for: busyState)?.isEmpty == false)
        }
        #expect(UpdateRestartGuard.blockingReason(for: .recording)?.contains("recording") == true)
        #expect(UpdateRestartGuard.blockingReason(for: .transcribing)?.contains("transcribing") == true)
        #expect(UpdateRestartGuard.blockingReason(for: .enhancing)?.contains("enhancing") == true)
    }

    @Test
    func busyEngineBlocksRestartAndOffersTheUpdateAgainWhenIdle() {
        let suiteName = "UpdateRestartGuardTests.busy"
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = RestartAdapterStub()
        let gate = UpdateRestartGate()
        let activity = PassthroughSubject<RecordingState, Never>()
        let updater = makeUpdater(defaults: defaults, adapter: adapter, gate: gate)
        updater.observeEngineActivity(activity.eraseToAnyPublisher())
        adapter.send(.stagedCandidate(candidate))

        activity.send(.recording)
        let reason = UpdateRestartGuard.blockingReason(for: .recording)
        #expect(updater.state.restartBlockedReason == reason)
        #expect(gate.blockingReason == reason)

        updater.restartAndUpdate()
        #expect(adapter.restartRequests.isEmpty)
        #expect(updater.state.stagedUpdate == candidate)
        #expect(!updater.state.isPresentingStagedUpdate)
        #expect(!updater.state.isPresentingRestartMessage)

        updater.showStagedUpdate()
        updater.restartWhenIdle()
        #expect(!updater.state.isPresentingStagedUpdate)
        #expect(updater.state.stagedUpdate == candidate)

        activity.send(.transcribing)
        #expect(!updater.state.isPresentingStagedUpdate)
        #expect(updater.state.restartBlockedReason == UpdateRestartGuard.blockingReason(for: .transcribing))

        activity.send(.idle)
        #expect(updater.state.restartBlockedReason == nil)
        #expect(gate.blockingReason == nil)
        #expect(updater.state.isPresentingStagedUpdate)
        #expect(updater.state.restartMessage == nil)

        updater.restartAndUpdate()
        #expect(adapter.restartRequests == [candidate])
        #expect(updater.state.stagedUpdate == nil)
        #expect(!updater.state.isPresentingStagedUpdate)
    }

    @Test
    func audioFileTranscriptionBlocksRestartAndTheInstallerQuit() {
        let suiteName = "UpdateRestartGuardTests.file-transcription"
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = RestartAdapterStub()
        let gate = UpdateRestartGate()
        let engineActivity = CurrentValueSubject<RecordingState, Never>(.idle)
        let fileActivity = FileTranscriptionActivity()
        let updater = makeUpdater(defaults: defaults, adapter: adapter, gate: gate)
        updater.observeEngineActivity(
            engineActivity.eraseToAnyPublisher(),
            fileTranscriptionActivity: fileActivity.$isActive.eraseToAnyPublisher()
        )
        adapter.send(.stagedCandidate(candidate))

        // Imported audio and a history retranscription overlap.
        fileActivity.begin()
        fileActivity.begin()
        #expect(updater.state.restartBlockedReason == UpdateRestartGuard.fileTranscriptionReason)
        #expect(gate.blockingReason == UpdateRestartGuard.fileTranscriptionReason)
        updater.restartAndUpdate()
        #expect(adapter.restartRequests.isEmpty)
        #expect(updater.state.stagedUpdate == candidate)

        fileActivity.end()
        #expect(gate.blockingReason == UpdateRestartGuard.fileTranscriptionReason)

        engineActivity.send(.recording)
        fileActivity.end()
        #expect(gate.blockingReason == UpdateRestartGuard.blockingReason(for: .recording))

        engineActivity.send(.idle)
        #expect(updater.state.restartBlockedReason == nil)
        #expect(gate.blockingReason == nil)
        updater.restartAndUpdate()
        #expect(adapter.restartRequests == [candidate])
    }

    @Test
    func idleTransitionDoesNotPresentTheUpdateUnlessTheUserAskedToTryAgain() {
        let suiteName = "UpdateRestartGuardTests.idle-without-request"
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = RestartAdapterStub()
        let activity = PassthroughSubject<RecordingState, Never>()
        let updater = makeUpdater(defaults: defaults, adapter: adapter, gate: UpdateRestartGate())
        updater.observeEngineActivity(activity.eraseToAnyPublisher())
        adapter.send(.stagedCandidate(candidate))
        updater.deferStagedUpdate()

        activity.send(.recording)
        activity.send(.idle)

        #expect(!updater.state.isPresentingStagedUpdate)
        #expect(updater.state.stagedUpdate == candidate)
    }

    @Test
    func rejectedRestartKeepsTheStagedUpdateAndExplainsWhy() {
        let suiteName = "UpdateRestartGuardTests.rejected"
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = RestartAdapterStub()
        adapter.restartError = ForkUpdateError(message: "The staged update changed. Check for updates again.")
        let updater = makeUpdater(defaults: defaults, adapter: adapter, gate: UpdateRestartGate())
        adapter.send(.stagedCandidate(candidate))

        updater.restartAndUpdate()

        #expect(updater.state.stagedUpdate == candidate)
        #expect(!updater.state.isPresentingStagedUpdate)
        #expect(updater.state.restartMessage == "The staged update changed. Check for updates again.")
        #expect(updater.state.isPresentingRestartMessage)
        #expect(updater.state.failure == nil)

        updater.dismissRestartMessage()
        #expect(!updater.state.isPresentingRestartMessage)
        #expect(updater.state.stagedUpdate == candidate)

        adapter.restartError = nil
        updater.restartAndUpdate()
        #expect(adapter.restartRequests == [candidate])
        #expect(updater.state.restartMessage == nil)
        #expect(updater.state.stagedUpdate == nil)
    }

    @Test
    func forkAdapterRejectsARestartForACandidateThatIsNotStaged() {
        let adapter = ForkUpdaterAdapter(
            transaction: CancellingTransactionStub(stagedCandidate: nil),
            resumeRequestObserver: ResumeObserverStub()
        )
        adapter.start()

        #expect(throws: ForkUpdateError.self) {
            try adapter.requestRestart(for: candidate)
        }
    }

    @Test
    func installerCancellationWhileBusyRestoresTheStagedUpdateWithoutAFailure() async throws {
        let suiteName = "UpdateRestartGuardTests.cancelled"
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let transaction = CancellingTransactionStub(stagedCandidate: candidate)
        let activity = PassthroughSubject<RecordingState, Never>()
        let updater = makeUpdater(
            defaults: defaults,
            adapter: ForkUpdaterAdapter(
                transaction: transaction,
                defaults: defaults,
                resumeRequestObserver: ResumeObserverStub()
            ),
            gate: UpdateRestartGate()
        )
        updater.observeEngineActivity(activity.eraseToAnyPublisher())
        #expect(updater.state.stagedUpdate == candidate)

        updater.restartAndUpdate()
        activity.send(.recording)
        try await waitUntil { transaction.restartRequestCount == 1 && !updater.state.isPreparingUpdate }

        #expect(updater.state.stagedUpdate == candidate)
        #expect(!updater.state.isPresentingStagedUpdate)
        #expect(updater.state.restartMessage == ForkUpdateRestartCancellation.busy.message)
        #expect(updater.state.failure == nil)
        #expect(transaction.persistedFailures.isEmpty)

        #expect(!updater.state.isPresentingRestartMessage)

        activity.send(.idle)
        #expect(updater.state.isPresentingStagedUpdate)
        #expect(updater.state.restartMessage == ForkUpdateRestartCancellation.busy.message)
    }

    @Test
    func busyInstallationOutcomeCleansUpAndCancelsTheRestart() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let manifestURL = temporaryDirectory.appendingPathComponent("staged-candidate.plist")
        let installedBundle = temporaryDirectory.appendingPathComponent("Installed.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: installedBundle.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(
            fromPropertyList: [
                SourceProvenance.forkCommitInfoKey: "3333333333333333333333333333333333333333",
            ],
            format: .xml,
            options: 0
        ).write(to: installedBundle.appendingPathComponent("Contents/Info.plist"))
        try PropertyListEncoder().encode(candidate).write(to: manifestURL, options: .atomic)
        let credentialStore = CredentialSnapshotRecorder()
        let transaction = ForkUpdateTransaction(
            scriptURL: temporaryDirectory.appendingPathComponent("prepare-local-update.sh"),
            manifestURL: manifestURL,
            installationScriptURL: temporaryDirectory.appendingPathComponent("install-local-update.sh"),
            targetBundleURL: installedBundle,
            backupBundleURL: temporaryDirectory.appendingPathComponent("Recovery/VoiceInk.app"),
            credentialSnapshotter: credentialStore,
            installationRunner: BusyInstallationRunnerStub(),
            logger: SilentLogger()
        )

        await #expect(throws: ForkUpdateRestartCancellation.self) {
            _ = try await transaction.requestRestart(for: candidate)
        }

        #expect(credentialStore.createdGenerations.count == 1)
        #expect(credentialStore.deletedGenerations == credentialStore.createdGenerations)
        #expect(!FileManager.default.fileExists(
            atPath: temporaryDirectory.appendingPathComponent("Recovery.pending").path
        ))
        #expect(try transaction.loadStagedCandidate() == candidate)
    }

    @Test
    func installerQuitRequestIsAnsweredFromTheApp() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let scriptURL = temporaryDirectory.appendingPathComponent("install-local-update.sh")
        let script = """
            #!/usr/bin/env bash
            printf 'request\\n' > "$VOICEINK_UPDATE_QUIT_REQUEST_PATH"
            for ((attempt = 0; attempt < 100; attempt++)); do
                if [[ -f "$VOICEINK_UPDATE_QUIT_RESPONSE_PATH" ]]; then
                    # The app claims the request before answering, so the installer
                    # can never withdraw it and signal a busy app.
                    [[ ! -e "$VOICEINK_UPDATE_QUIT_REQUEST_PATH" \
                        && -e "$VOICEINK_UPDATE_QUIT_REQUEST_PATH.claimed" ]] || exit 2
                    [[ "$(< "$VOICEINK_UPDATE_QUIT_RESPONSE_PATH")" == busy ]] && exit 76
                    exit 0
                fi
                sleep 0.05
            done
            exit 1
            """
        try Data(script.utf8).write(to: scriptURL)
        let request = ForkUpdateInstallationRequest(
            scriptURL: scriptURL,
            candidate: candidate,
            manifestURL: temporaryDirectory.appendingPathComponent("manifest.plist"),
            targetBundleURL: temporaryDirectory.appendingPathComponent("Target.app"),
            backupBundleURL: temporaryDirectory.appendingPathComponent("Backup.app"),
            parentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            credentialGeneration: UUID().uuidString.lowercased()
        )

        let busyHandler = QuitRequestHandlerStub(response: .busy)
        let busyOutcome = try await ProcessForkUpdateInstallationRunner(
            retryDelays: [],
            logger: SilentLogger(),
            quitRequestHandler: busyHandler
        ).install(request)
        #expect(busyOutcome == .cancelledWhileBusy)
        #expect(busyHandler.requestCount == 1)

        let quitHandler = QuitRequestHandlerStub(response: .quit)
        let quitOutcome = try await ProcessForkUpdateInstallationRunner(
            retryDelays: [],
            logger: SilentLogger(),
            quitRequestHandler: quitHandler
        ).install(request)
        #expect(quitOutcome == .completed)
        #expect(quitHandler.requestCount == 1)
    }

    private func makeUpdater(
        defaults: UserDefaults,
        adapter: any UpdaterAdapter,
        gate: UpdateRestartGate
    ) -> UpdaterViewModel {
        UpdaterViewModel(
            defaults: defaults,
            adapter: adapter,
            sourceProvenance: nil,
            notificationDeliverer: SilentNotificationDeliverer(),
            restartGate: gate
        )
    }

    private func makeDefaults(suiteName: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for updater state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class RestartAdapterStub: UpdaterAdapter {
    var state = UpdaterAdapterState(
        canCheckForUpdates: true,
        sessionInProgress: false,
        lastUpdateCheckDate: nil,
        updateCheckInterval: 60
    )
    var onEvent: ((UpdaterAdapterEvent) -> Void)?
    var restartError: Error?
    private(set) var restartRequests: [StagedForkCandidate] = []

    func start() {}
    func checkForUpdateInformation() {}
    func checkForUpdates() {}

    func requestRestart(for candidate: StagedForkCandidate) throws {
        if let restartError { throw restartError }
        restartRequests.append(candidate)
    }

    func send(_ event: UpdaterAdapterEvent) {
        onEvent?(event)
    }
}

@MainActor
private final class CancellingTransactionStub: ForkUpdateTransacting {
    let stagedCandidate: StagedForkCandidate?
    private(set) var restartRequestCount = 0
    private(set) var persistedFailures: [ForkUpdateFailure] = []
    var canRestorePreviousVersion: Bool { false }

    init(stagedCandidate: StagedForkCandidate?) {
        self.stagedCandidate = stagedCandidate
    }

    func loadStagedCandidate() throws -> StagedForkCandidate? { stagedCandidate }
    func loadPersistentFailure() throws -> ForkUpdateFailure? { nil }
    func loadPersistentRollbackNotice() throws -> LocalUpdateRollbackNotice? { nil }
    func persistFailure(_ failure: ForkUpdateFailure) throws { persistedFailures.append(failure) }
    func clearPersistentFailure() throws {}
    func clearPersistentRollbackNotice() throws {}

    func prepare(mode: ForkUpdatePreparationMode) async throws -> ForkUpdatePreparationResult {
        throw ForkUpdateError(message: "Unexpected preparation.")
    }

    func requestRestart(for candidate: StagedForkCandidate) async throws -> StagedForkCandidate? {
        restartRequestCount += 1
        try await Task.sleep(for: .milliseconds(20))
        throw ForkUpdateRestartCancellation.busy
    }

    func restorePreviousVersion() async throws {}
}

@MainActor
private final class ResumeObserverStub: ForkUpdateResumeRequestObserving {
    func observe(_ handler: @escaping (String) -> Void) {}
}

private final class SilentNotificationDeliverer: ForkUpdateNotificationDelivering {
    func deliver(_ notification: ForkUpdateUserNotification, action: @escaping () -> Void) {}
}

private struct SilentLogger: ForkUpdateLogging {
    func record(_ record: ForkUpdateLogRecord) async {}
}

private struct BusyInstallationRunnerStub: ForkUpdateInstalling {
    func install(_ request: ForkUpdateInstallationRequest) async throws -> ForkUpdateInstallationOutcome {
        .cancelledWhileBusy
    }
}

private final class CredentialSnapshotRecorder: ForkUpdateCredentialSnapshotting {
    private(set) var createdGenerations: [String] = []
    private(set) var deletedGenerations: [String] = []

    func createSnapshot(generationIdentifier: String) throws {
        createdGenerations.append(generationIdentifier)
    }

    func deleteSnapshot(generationIdentifier: String) throws {
        deletedGenerations.append(generationIdentifier)
    }
}

private final class QuitRequestHandlerStub: ForkUpdateQuitRequestHandling, @unchecked Sendable {
    private let lock = NSLock()
    private let response: ForkUpdateQuitResponse
    private var count = 0

    init(response: ForkUpdateQuitResponse) {
        self.response = response
    }

    var requestCount: Int {
        lock.withLock { count }
    }

    func handleQuitRequest(respond: (ForkUpdateQuitResponse) -> Void) {
        lock.withLock { count += 1 }
        respond(response)
    }
}
