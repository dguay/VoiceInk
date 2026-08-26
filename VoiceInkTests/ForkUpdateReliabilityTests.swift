import Foundation
import Testing
@testable import VoiceInk

@Suite(.serialized)
struct ForkUpdateReliabilityTests {
    @Test
    func transientNetworkFailureRetriesWithinTheBound() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let scriptURL = temporaryDirectory.appendingPathComponent("prepare-local-update.sh")
        let attemptsURL = temporaryDirectory.appendingPathComponent("attempts")
        let forkCommit = "0123456789abcdef0123456789abcdef01234567"
        let upstreamCommit = "fedcba9876543210fedcba9876543210fedcba98"
        let script = """
            #!/usr/bin/env bash
            set -euo pipefail
            attempts_file="$(dirname "$0")/attempts"
            attempts=0
            [[ ! -f "$attempts_file" ]] || attempts="$(< "$attempts_file")"
            attempts=$((attempts + 1))
            printf '%s' "$attempts" > "$attempts_file"
            if [[ "$attempts" -lt 3 ]]; then
                printf 'fatal: unable to access repository: Could not resolve host\n' >&2
                exit 1
            fi
            printf 'fetch\nmerge\n' > "$VOICEINK_UPDATE_PROGRESS_PATH"
            /usr/bin/plutil -create xml1 "$VOICEINK_UPDATE_RESULT_PATH"
            /usr/bin/plutil -insert outcome -string upToDate "$VOICEINK_UPDATE_RESULT_PATH"
            /usr/bin/plutil -insert forkCommit -string \(forkCommit) "$VOICEINK_UPDATE_RESULT_PATH"
            /usr/bin/plutil -insert upstreamCommit -string \(upstreamCommit) "$VOICEINK_UPDATE_RESULT_PATH"
            """
        try Data(script.utf8).write(to: scriptURL)
        let delays = DelayRecorder()
        let logger = ForkUpdateLogRecorder()

        let result = try await ProcessForkUpdateCommandRunner(
            retryDelays: [1, 2],
            sleep: { delay in await delays.record(delay) },
            logger: logger
        ).run(
            scriptURL: scriptURL,
            manifestURL: temporaryDirectory.appendingPathComponent("staged-candidate.plist"),
            installedForkCommit: nil,
            mode: .automatic(deferBuild: false)
        )

        #expect(
            result == .upToDate(
                SourceProvenance(forkCommit: forkCommit, upstreamCommit: upstreamCommit)
            )
        )
        #expect(try String(contentsOf: attemptsURL, encoding: .utf8) == "3")
        #expect(await delays.values == [1, 2])
        let records = await logger.records
        #expect(records.contains { $0.stage == .fetch && $0.outcome == .succeeded })
        #expect(records.contains { $0.stage == .merge && $0.outcome == .succeeded })
    }

    @Test
    func incompatibleToolchainIsReportedWithoutRetrying() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let scriptURL = temporaryDirectory.appendingPathComponent("prepare-local-update.sh")
        let attemptsURL = temporaryDirectory.appendingPathComponent("attempts")
        let script = """
            #!/usr/bin/env bash
            attempts_file="$(dirname "$0")/attempts"
            attempts=0
            [[ ! -f "$attempts_file" ]] || attempts="$(< "$attempts_file")"
            printf '%s' "$((attempts + 1))" > "$attempts_file"
            printf 'xcode-select: error: tool xcodebuild requires Xcode 27\n' >&2
            exit 1
            """
        try Data(script.utf8).write(to: scriptURL)

        do {
            _ = try await ProcessForkUpdateCommandRunner(
                retryDelays: [0, 0],
                sleep: { _ in }
            ).run(
                scriptURL: scriptURL,
                manifestURL: temporaryDirectory.appendingPathComponent("staged-candidate.plist"),
                installedForkCommit: nil,
                mode: .manual
            )
            Issue.record("Expected an incompatible toolchain failure")
        } catch let failure as ForkUpdateFailure {
            #expect(failure.stage == .toolchain)
            #expect(failure.recoverySuggestion.contains("Install or upgrade Xcode manually"))
        }

        #expect(try String(contentsOf: attemptsURL, encoding: .utf8) == "1")
    }

    @Test
    func installationRunnerReportsAnAutomaticRollbackOutcomeSeparately() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let scriptURL = temporaryDirectory.appendingPathComponent("install-local-update.sh")
        try Data("""
            #!/usr/bin/env bash
            printf 'Error: Candidate health verification failed.\n' >&2
            printf 'VoiceInk automatic rollback succeeded.\n' >&2
            exit 1
            """.utf8).write(to: scriptURL)
        let candidate = StagedForkCandidate(
            forkCommit: "0123456789abcdef0123456789abcdef01234567",
            upstreamCommit: "fedcba9876543210fedcba9876543210fedcba98",
            bundleURL: temporaryDirectory.appendingPathComponent("VoiceInk.app"),
            preparedAt: Date(timeIntervalSince1970: 1_787_400_000)
        )

        do {
            _ = try await ProcessForkUpdateInstallationRunner().install(
                ForkUpdateInstallationRequest(
                    scriptURL: scriptURL,
                    candidate: candidate,
                    manifestURL: temporaryDirectory.appendingPathComponent("candidate.plist"),
                    targetBundleURL: temporaryDirectory.appendingPathComponent("Installed.app"),
                    backupBundleURL: temporaryDirectory.appendingPathComponent("Recovery.app"),
                    parentProcessIdentifier: 1,
                    credentialGeneration: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                )
            )
            Issue.record("Expected the installation helper to fail after rollback")
        } catch let error as ForkUpdateError {
            #expect(error.rollbackOutcome == .succeeded)
            #expect(!error.failureDescription.contains("rollback succeeded"))
            #expect(error.failureDescription.contains("health verification failed"))
        }
    }

    @Test
    func updateLogsRedactSensitiveFieldsAndRetainTheNewestUnresolvedFailure() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let now = Date(timeIntervalSince1970: 1_787_400_000)
        let logger = ForkUpdateLogStore(
            directoryURL: temporaryDirectory,
            now: { now },
            maximumAge: 30 * 24 * 60 * 60,
            maximumBytes: 6_000
        )
        await logger.record(
            ForkUpdateLogRecord(
                timestamp: now.addingTimeInterval(-31 * 24 * 60 * 60),
                attemptIdentifier: "expired",
                stage: .fetch,
                outcome: .failed,
                candidateIdentifier: nil,
                forkCommit: nil,
                upstreamCommit: nil,
                retry: 2,
                message: "expired"
            )
        )
        await logger.record(
            ForkUpdateLogRecord(
                timestamp: now,
                attemptIdentifier: "unresolved",
                stage: .permission,
                outcome: .failed,
                candidateIdentifier: "candidate-1",
                forkCommit: "0123456789abcdef0123456789abcdef01234567",
                upstreamCommit: "fedcba9876543210fedcba9876543210fedcba98",
                retry: 1,
                message: "transcript=very private phrase\nselectedText=multi word selection\nclipboard=copied phrase\nscreenshot=private image\nAuthorization: Bearer api-secret"
            )
        )
        for index in 0 ..< 6 {
            await logger.record(
                ForkUpdateLogRecord(
                    timestamp: now.addingTimeInterval(TimeInterval(index + 1)),
                    attemptIdentifier: "resolved-\(index)",
                    stage: .build,
                    outcome: .succeeded,
                    candidateIdentifier: "candidate-\(index + 2)",
                    forkCommit: nil,
                    upstreamCommit: nil,
                    retry: nil,
                    message: String(repeating: "build evidence ", count: 45)
                )
            )
        }

        let records = await logger.loadRecords()
        let storedText = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ).map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        let storedBytes = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ).reduce(0) { total, url in
            total + ((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        #expect(!records.contains { $0.attemptIdentifier == "expired" })
        #expect(records.contains { $0.attemptIdentifier == "unresolved" && $0.retry == 1 })
        #expect(!storedText.contains("api-secret"))
        #expect(!storedText.contains("private"))
        #expect(!storedText.contains("phrase"))
        #expect(!storedText.contains("selection"))
        #expect(!storedText.contains("clipboard=copy"))
        #expect(!storedText.contains("screenshot=image"))
        #expect(storedBytes <= 6_000)
    }

    @Test
    func logRetentionPreservesAnUnresolvedPreflightFailureWithoutACandidate() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let now = Date(timeIntervalSince1970: 1_787_400_000)
        let logger = ForkUpdateLogStore(
            directoryURL: temporaryDirectory,
            now: { now },
            maximumAge: 1,
            maximumBytes: 1
        )
        await logger.record(
            ForkUpdateLogRecord(
                timestamp: now.addingTimeInterval(-60),
                attemptIdentifier: "preflight-failure",
                stage: .fetch,
                outcome: .failed,
                candidateIdentifier: nil,
                forkCommit: nil,
                upstreamCommit: nil,
                retry: 2,
                message: "The fork could not be reached."
            )
        )

        let records = await logger.loadRecords()

        #expect(records.contains { $0.attemptIdentifier == "preflight-failure" })
    }

    @Test @MainActor
    func persistentFailureTakesPrecedenceOverAStagedCandidateOnRelaunch() {
        let candidate = StagedForkCandidate(
            forkCommit: "0123456789abcdef0123456789abcdef01234567",
            upstreamCommit: "fedcba9876543210fedcba9876543210fedcba98",
            bundleURL: URL(fileURLWithPath: "/tmp/VoiceInk.app"),
            preparedAt: Date(timeIntervalSince1970: 1_787_400_000)
        )
        let failure = ForkUpdateFailure.reported(
            stage: .installation,
            kind: .deterministic,
            candidateIdentifier: candidate.forkCommit,
            message: "The previous installation attempt failed."
        )
        let adapter = ForkUpdaterAdapter(
            transaction: ForkUpdateStartupTransactionStub(candidate: candidate, failure: failure)
        )
        var presentedFailure: ForkUpdateFailure?
        var presentedCandidate = false
        adapter.onEvent = { event in
            switch event {
            case .preparationFailed(let receivedFailure):
                presentedFailure = receivedFailure
            case .stagedCandidate:
                presentedCandidate = true
            default:
                break
            }
        }

        adapter.start()

        #expect(presentedFailure == failure)
        #expect(!presentedCandidate)
    }

    @Test @MainActor
    func updaterDeduplicatesActionableCandidateFailureAndRollbackNotifications() {
        let suiteName = "ForkUpdateReliabilityTests.notifications"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = ReliabilityUpdaterAdapterStub()
        let notifications = ForkUpdateNotificationRecorder()
        let logOpener = ForkUpdateLogOpenerRecorder()
        let updater: any UpdaterModule = UpdaterViewModel(
            defaults: defaults,
            adapter: adapter,
            notificationDeliverer: notifications,
            logOpener: logOpener
        )
        let candidate = StagedForkCandidate(
            forkCommit: "0123456789abcdef0123456789abcdef01234567",
            upstreamCommit: "fedcba9876543210fedcba9876543210fedcba98",
            bundleURL: URL(fileURLWithPath: "/tmp/VoiceInk.app"),
            preparedAt: Date(timeIntervalSince1970: 1_787_400_000)
        )
        let failure = ForkUpdateFailure(
            stage: .permission,
            kind: .deterministic,
            candidateIdentifier: candidate.forkCommit,
            message: "Accessibility permission no longer matches the previous app.",
            recoverySuggestion: "Review permissions and restore if needed."
        )

        adapter.send(.stagedCandidate(candidate))
        adapter.send(.stagedCandidate(candidate))
        adapter.send(.preparationFailed(failure))
        adapter.send(.preparationFailed(failure))
        #expect(updater.state.failure == failure)
        adapter.send(.rollbackCompleted)

        #expect(
            notifications.notifications.map(\.kind)
                == [.candidateReady, .permissionRegression, .rollbackSucceeded]
        )
        #expect(updater.state.failure == nil)

        updater.openUpdateLogs()
        updater.checkForUpdates()

        #expect(logOpener.openCount == 1)
        #expect(adapter.updateCheckCount == 1)
        #expect(updater.state.failure == nil)
    }
}

private actor DelayRecorder {
    private(set) var values: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        values.append(value)
    }
}

private actor ForkUpdateLogRecorder: ForkUpdateLogging {
    private(set) var records: [ForkUpdateLogRecord] = []

    func record(_ record: ForkUpdateLogRecord) {
        records.append(record)
    }
}

@MainActor
private final class ForkUpdateStartupTransactionStub: ForkUpdateTransacting {
    let candidate: StagedForkCandidate
    let failure: ForkUpdateFailure
    var canRestorePreviousVersion = false

    init(candidate: StagedForkCandidate, failure: ForkUpdateFailure) {
        self.candidate = candidate
        self.failure = failure
    }

    func loadStagedCandidate() throws -> StagedForkCandidate? { candidate }
    func loadPersistentFailure() throws -> ForkUpdateFailure? { failure }
    func prepare(mode: ForkUpdatePreparationMode) async throws -> ForkUpdatePreparationResult {
        .staged(candidate)
    }
    func requestRestart(for candidate: StagedForkCandidate) async throws -> StagedForkCandidate? { nil }
    func restorePreviousVersion() async throws {}
}

@MainActor
private final class ReliabilityUpdaterAdapterStub: UpdaterAdapter {
    var state = UpdaterAdapterState(
        canCheckForUpdates: true,
        sessionInProgress: false,
        lastUpdateCheckDate: nil,
        updateCheckInterval: 24 * 60 * 60
    )
    var onEvent: ((UpdaterAdapterEvent) -> Void)?
    var canRestorePreviousVersion = true
    private(set) var updateCheckCount = 0

    func start() {}
    func checkForUpdateInformation() {}
    func checkForUpdates() { updateCheckCount += 1 }
    func requestRestart(for candidate: StagedForkCandidate) {}
    func restorePreviousVersion() {}
    func send(_ event: UpdaterAdapterEvent) { onEvent?(event) }
}

@MainActor
private final class ForkUpdateNotificationRecorder: ForkUpdateNotificationDelivering {
    private(set) var notifications: [ForkUpdateUserNotification] = []

    func deliver(_ notification: ForkUpdateUserNotification, action: @escaping () -> Void) {
        notifications.append(notification)
    }
}

@MainActor
private final class ForkUpdateLogOpenerRecorder: ForkUpdateLogOpening {
    private(set) var openCount = 0

    func openLogs() {
        openCount += 1
    }
}
