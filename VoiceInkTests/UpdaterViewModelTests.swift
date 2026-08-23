import Foundation
import Testing
@testable import VoiceInk

@MainActor
struct UpdaterViewModelTests {
    @Test
    func officialUpdaterBehaviorFlowsThroughTheUpdaterInterface() {
        let suiteName = "UpdaterViewModelTests.official"
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = OfficialUpdaterAdapterStub(canCheckForUpdates: true)
        let updater: any UpdaterModule = UpdaterViewModel(defaults: defaults, adapter: adapter)

        #expect(adapter.startCount == 1)
        #expect(updater.state.canCheckForUpdates)

        adapter.send(.foundUpdate(versionIdentifier: "212", displayVersion: "2.12"))
        #expect(updater.state.availableUpdate?.displayVersion == "2.12")

        updater.checkForUpdates()

        #expect(adapter.userInitiatedCheckCount == 1)
        #expect(updater.state.availableUpdate == nil)
    }

    @Test
    func localUpdaterExposesNoAvailableUpdateAction() {
        let suiteName = "UpdaterViewModelTests.local"
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let updater: any UpdaterModule = UpdaterViewModel(
            defaults: defaults,
            adapter: ForkUpdaterAdapter()
        )

        #expect(!updater.state.canCheckForUpdates)
        #expect(updater.state.availableUpdate == nil)

        updater.checkForUpdates()

        #expect(!updater.state.canCheckForUpdates)
        #expect(updater.state.availableUpdate == nil)
    }

    @Test
    func manualForkUpdateStagesCandidateWithoutRequestingAppTermination() async throws {
        let suiteName = "UpdaterViewModelTests.staging"
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let candidate = StagedForkCandidate(
            forkCommit: "0123456789abcdef0123456789abcdef01234567",
            upstreamCommit: "fedcba9876543210fedcba9876543210fedcba98",
            bundleURL: URL(fileURLWithPath: "/tmp/VoiceInk.app"),
            preparedAt: Date(timeIntervalSince1970: 1_787_400_000)
        )
        let transaction = ForkUpdateTransactionStub(stagedCandidate: candidate)
        let updater: any UpdaterModule = UpdaterViewModel(
            defaults: defaults,
            adapter: ForkUpdaterAdapter(transaction: transaction)
        )

        updater.checkForUpdates()
        try await waitUntil { updater.state.stagedUpdate == candidate }

        #expect(transaction.prepareCount == 1)
        #expect(updater.state.isPresentingStagedUpdate)
        #expect(transaction.restartRequestCount == 0)

        updater.deferStagedUpdate()
        #expect(!updater.state.isPresentingStagedUpdate)
        #expect(updater.state.stagedUpdate == candidate)

        updater.showStagedUpdate()
        updater.restartAndUpdate()
        try await waitUntil { transaction.restartRequestCount == 1 }
        #expect(transaction.restartRequestCount == 1)
        #expect(!updater.state.isPresentingStagedUpdate)
    }

    @Test
    func staleRestartApprovalReturnsToPreparationForTheNewCandidate() async throws {
        let suiteName = "UpdaterViewModelTests.stale-restart"
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let approvedCandidate = StagedForkCandidate(
            forkCommit: "1111111111111111111111111111111111111111",
            upstreamCommit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            bundleURL: URL(fileURLWithPath: "/tmp/approved/VoiceInk.app"),
            preparedAt: Date(timeIntervalSince1970: 1_787_400_200)
        )
        let replacementCandidate = StagedForkCandidate(
            forkCommit: "2222222222222222222222222222222222222222",
            upstreamCommit: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            bundleURL: URL(fileURLWithPath: "/tmp/replacement/VoiceInk.app"),
            preparedAt: Date(timeIntervalSince1970: 1_787_400_300)
        )
        let transaction = ForkUpdateTransactionStub(
            stagedCandidate: approvedCandidate,
            restartResult: replacementCandidate
        )
        let updater: any UpdaterModule = UpdaterViewModel(
            defaults: defaults,
            adapter: ForkUpdaterAdapter(transaction: transaction)
        )

        updater.checkForUpdates()
        try await waitUntil { updater.state.stagedUpdate == approvedCandidate }
        updater.restartAndUpdate()
        try await waitUntil { updater.state.stagedUpdate == replacementCandidate }

        #expect(transaction.restartRequestCount == 1)
        #expect(updater.state.isPresentingStagedUpdate)
    }

    @Test
    func restartSnapshotsCredentialsBeforeStartingTheInstaller() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let manifestURL = temporaryDirectory.appendingPathComponent("staged-candidate.plist")
        let candidate = StagedForkCandidate(
            forkCommit: "1111111111111111111111111111111111111111",
            upstreamCommit: "2222222222222222222222222222222222222222",
            bundleURL: temporaryDirectory.appendingPathComponent("VoiceInk.app"),
            preparedAt: Date(timeIntervalSince1970: 1_787_400_400)
        )
        try PropertyListEncoder().encode(candidate).write(to: manifestURL, options: .atomic)
        let recorder = ForkUpdateRestartRecorder()
        let transaction = ForkUpdateTransaction(
            scriptURL: temporaryDirectory.appendingPathComponent("prepare-local-update.sh"),
            manifestURL: manifestURL,
            installationScriptURL: temporaryDirectory.appendingPathComponent("install-local-update.sh"),
            targetBundleURL: temporaryDirectory.appendingPathComponent("Installed.app"),
            backupBundleURL: temporaryDirectory.appendingPathComponent("Recovery/VoiceInk.app"),
            credentialSnapshotter: ForkUpdateCredentialSnapshotterStub(recorder: recorder),
            installationRunner: ForkUpdateInstallationRunnerStub(recorder: recorder)
        )

        _ = try await transaction.requestRestart(for: candidate)

        #expect(recorder.events == [.credentialsSnapshotted, .installerStarted])
    }

    @Test
    func recoveryCommandRestoresTheKeychainSnapshotWithoutStartingTheApp() throws {
        let credentialStore = ForkUpdateCredentialRestorerStub()

        let handled = try LocalUpdateCredentialRecoveryCommand.runIfRequested(
            arguments: ["VoiceInk", "--voiceink-restore-update-credentials"],
            credentialStore: credentialStore
        )

        #expect(handled)
        #expect(credentialStore.restoreCount == 1)
    }

    @Test
    func restorePreviousVersionFlowsThroughTheUpdaterInterface() {
        let suiteName = "UpdaterViewModelTests.restore"
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = OfficialUpdaterAdapterStub(canCheckForUpdates: true)
        adapter.canRestorePreviousVersion = true
        let updater: any UpdaterModule = UpdaterViewModel(defaults: defaults, adapter: adapter)

        #expect(updater.state.canRestorePreviousVersion)
        updater.showRestorePreviousVersion()
        #expect(updater.state.isPresentingRestorePreviousVersion)
        updater.cancelRestorePreviousVersion()
        #expect(!updater.state.isPresentingRestorePreviousVersion)
        updater.showRestorePreviousVersion()
        updater.restorePreviousVersion()

        #expect(adapter.restorePreviousVersionCount == 1)
        #expect(!updater.state.isPresentingRestorePreviousVersion)
    }

    @Test
    func manualRestoreUsesTheRetainedRecoveryTransaction() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let installedBundle = temporaryDirectory.appendingPathComponent("Installed.app", isDirectory: true)
        let backupBundle = temporaryDirectory.appendingPathComponent("Recovery/VoiceInk.app", isDirectory: true)
        let recoveryManifest = temporaryDirectory.appendingPathComponent("Recovery/recovery.plist")
        try FileManager.default.createDirectory(
            at: installedBundle.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: backupBundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let candidateCommit = "1111111111111111111111111111111111111111"
        let info: [String: Any] = [SourceProvenance.forkCommitInfoKey: candidateCommit]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: installedBundle.appendingPathComponent("Contents/Info.plist"))
        try PropertyListEncoder().encode(
            LocalUpdateRecoveryState(
                previousForkCommit: "2222222222222222222222222222222222222222",
                candidateForkCommit: candidateCommit
            )
        ).write(to: recoveryManifest)
        let restoreRunner = ForkUpdateRestoreRunnerStub()
        let transaction = ForkUpdateTransaction(
            scriptURL: temporaryDirectory.appendingPathComponent("prepare-local-update.sh"),
            manifestURL: temporaryDirectory.appendingPathComponent("staged-candidate.plist"),
            restorationScriptURL: temporaryDirectory.appendingPathComponent("restore-local-update.sh"),
            targetBundleURL: installedBundle,
            backupBundleURL: backupBundle,
            restorationRunner: restoreRunner
        )

        #expect(transaction.canRestorePreviousVersion)
        try await transaction.restorePreviousVersion()

        #expect(restoreRunner.restoreCount == 1)
    }

    @Test
    func stagedCandidateIsRestoredFromThePersistentManifest() throws {
        let suiteName = "UpdaterViewModelTests.restored-staging"
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let manifestURL = temporaryDirectory.appendingPathComponent("staged-candidate.plist")
        let candidate = StagedForkCandidate(
            forkCommit: "1111111111111111111111111111111111111111",
            upstreamCommit: "2222222222222222222222222222222222222222",
            bundleURL: temporaryDirectory.appendingPathComponent("VoiceInk.app"),
            preparedAt: Date(timeIntervalSince1970: 1_787_400_100)
        )
        try PropertyListEncoder().encode(candidate).write(to: manifestURL, options: .atomic)
        let transaction = ForkUpdateTransaction(
            scriptURL: temporaryDirectory.appendingPathComponent("prepare-local-update.sh"),
            manifestURL: manifestURL,
            commandRunner: ForkUpdateCommandRunnerStub()
        )

        let updater: any UpdaterModule = UpdaterViewModel(
            defaults: defaults,
            adapter: ForkUpdaterAdapter(transaction: transaction)
        )

        #expect(updater.state.stagedUpdate == candidate)
        #expect(updater.state.isPresentingStagedUpdate)
    }

    @Test
    func installedSourceProvenanceFlowsThroughTheUpdaterInterface() {
        let suiteName = "UpdaterViewModelTests.provenance"
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provenance = SourceProvenance(
            forkCommit: "0123456789abcdef",
            upstreamCommit: "fedcba9876543210"
        )
        let updater: any UpdaterModule = UpdaterViewModel(
            defaults: defaults,
            adapter: ForkUpdaterAdapter(),
            sourceProvenance: provenance
        )

        #expect(updater.state.sourceProvenance == provenance)
    }

    @Test
    func sourceProvenanceReadsTheLocalBuildBundleContract() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.voiceink.tests.provenance",
            SourceProvenance.forkCommitInfoKey: "0123456789abcdef0123456789abcdef01234567",
            SourceProvenance.upstreamCommitInfoKey: "fedcba9876543210fedcba9876543210fedcba98",
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let bundle = try #require(Bundle(url: bundleURL))
        #expect(
            SourceProvenance.from(bundle: bundle) == SourceProvenance(
                forkCommit: "0123456789abcdef0123456789abcdef01234567",
                upstreamCommit: "fedcba9876543210fedcba9876543210fedcba98"
            ))
    }

    @Test
    func launchedLocalBuildReportsItsTransactionHealth() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = temporaryDirectory.appendingPathComponent("VoiceInk.bundle", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let healthURL = temporaryDirectory.appendingPathComponent("health.plist")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.voiceink.tests.health",
            SourceProvenance.forkCommitInfoKey: "0123456789abcdef0123456789abcdef01234567",
            SourceProvenance.upstreamCommitInfoKey: "fedcba9876543210fedcba9876543210fedcba98",
            "VoiceInkUpdaterKind": "fork",
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: bundleURL))

        try LocalUpdateHealthReporter.reportIfRequested(
            arguments: ["VoiceInk", "--voiceink-update-health-path", healthURL.path],
            bundle: bundle,
            processIdentifier: 4_321
        )

        let report = try PropertyListDecoder().decode(
            LocalUpdateHealthReport.self,
            from: Data(contentsOf: healthURL)
        )
        #expect(report.forkCommit == "0123456789abcdef0123456789abcdef01234567")
        #expect(report.upstreamCommit == "fedcba9876543210fedcba9876543210fedcba98")
        #expect(report.updaterKind == "fork")
        #expect(report.processIdentifier == 4_321)
    }

    @Test
    func sourceProvenanceRejectsUnexpandedBuildSettings() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.voiceink.tests.empty-provenance",
            SourceProvenance.forkCommitInfoKey: "$(VOICEINK_FORK_COMMIT)",
            SourceProvenance.upstreamCommitInfoKey: "$(VOICEINK_UPSTREAM_COMMIT)",
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let bundle = try #require(Bundle(url: bundleURL))
        #expect(SourceProvenance.from(bundle: bundle) == nil)
    }

    @Test
    func productionAdapterMatchesTheBuildConfiguration() {
        #if LOCAL_BUILD
            let adapter = ProductionUpdaterAdapter.make()
            #expect(adapter is ForkUpdaterAdapter)
            #expect(adapter.state.canCheckForUpdates)
        #else
            #expect(ProductionUpdaterAdapter.make() is SparkleUpdaterAdapter)
        #endif
    }

    @Test
    func automaticCheckPreferenceMigratesFromSparkleWithoutLosingTheChoice() {
        let suiteName = "UpdaterViewModelTests.migration"
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "SUEnableAutomaticChecks")

        let updater: any UpdaterModule = UpdaterViewModel(
            defaults: defaults,
            adapter: OfficialUpdaterAdapterStub(canCheckForUpdates: true)
        )

        #expect(!updater.state.checksForUpdatesWhenDashboardAppears)
        #expect(defaults.object(forKey: "VoiceInkChecksForUpdatesOnLaunch") as? Bool == false)
    }

    private func makeDefaults(suiteName: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
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
private final class ForkUpdateTransactionStub: ForkUpdateTransacting {
    let stagedCandidate: StagedForkCandidate
    let restartResult: StagedForkCandidate?
    private(set) var prepareCount = 0
    private(set) var restartRequestCount = 0
    var canRestorePreviousVersion = false
    private(set) var restorePreviousVersionCount = 0

    init(stagedCandidate: StagedForkCandidate, restartResult: StagedForkCandidate? = nil) {
        self.stagedCandidate = stagedCandidate
        self.restartResult = restartResult
    }

    func loadStagedCandidate() throws -> StagedForkCandidate? {
        nil
    }

    func prepare() async throws -> StagedForkCandidate {
        prepareCount += 1
        return stagedCandidate
    }

    func requestRestart(for candidate: StagedForkCandidate) async throws -> StagedForkCandidate? {
        restartRequestCount += 1
        return restartResult
    }

    func restorePreviousVersion() async throws {
        restorePreviousVersionCount += 1
    }
}

private struct ForkUpdateCommandRunnerStub: ForkUpdateCommandRunning {
    func run(
        scriptURL: URL,
        manifestURL: URL,
        retrySuppressedCandidate: Bool
    ) async throws {}
}

private final class ForkUpdateRestartRecorder: @unchecked Sendable {
    enum Event: Equatable {
        case credentialsSnapshotted
        case installerStarted
    }

    var events: [Event] = []
}

private struct ForkUpdateCredentialSnapshotterStub: ForkUpdateCredentialSnapshotting {
    let recorder: ForkUpdateRestartRecorder

    func createSnapshot() throws {
        recorder.events.append(.credentialsSnapshotted)
    }
}

private final class ForkUpdateCredentialRestorerStub: ForkUpdateCredentialRestoring, @unchecked Sendable {
    private(set) var restoreCount = 0

    func restoreSnapshot() throws {
        restoreCount += 1
    }
}

private struct ForkUpdateInstallationRunnerStub: ForkUpdateInstalling {
    let recorder: ForkUpdateRestartRecorder

    func install(_ request: ForkUpdateInstallationRequest) async throws -> ForkUpdateInstallationOutcome {
        recorder.events.append(.installerStarted)
        return .completed
    }
}

private final class ForkUpdateRestoreRunnerStub: ForkUpdateRestoring, @unchecked Sendable {
    private(set) var restoreCount = 0

    func restore(_ request: ForkUpdateRestorationRequest) async throws {
        restoreCount += 1
    }
}

@MainActor
private final class OfficialUpdaterAdapterStub: UpdaterAdapter {
    var state: UpdaterAdapterState
    var onEvent: ((UpdaterAdapterEvent) -> Void)?
    private(set) var startCount = 0
    private(set) var userInitiatedCheckCount = 0
    private(set) var informationCheckCount = 0
    var canRestorePreviousVersion = false
    private(set) var restorePreviousVersionCount = 0

    init(canCheckForUpdates: Bool) {
        state = UpdaterAdapterState(
            canCheckForUpdates: canCheckForUpdates,
            sessionInProgress: false,
            lastUpdateCheckDate: nil,
            updateCheckInterval: 60
        )
    }

    func start() {
        startCount += 1
    }

    func checkForUpdateInformation() {
        informationCheckCount += 1
    }

    func checkForUpdates() {
        userInitiatedCheckCount += 1
    }

    func restorePreviousVersion() {
        restorePreviousVersionCount += 1
    }

    func send(_ event: UpdaterAdapterEvent) {
        onEvent?(event)
    }
}
