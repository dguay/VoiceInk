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
    func localUpdateFailureReplacesTheStagedActionWithItsError() {
        let suiteName = "UpdaterViewModelTests.local-update-failure"
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = OfficialUpdaterAdapterStub(canCheckForUpdates: false)
        let updater: any UpdaterModule = UpdaterViewModel(defaults: defaults, adapter: adapter)
        let candidate = StagedForkCandidate(
            forkCommit: "0123456789abcdef0123456789abcdef01234567",
            upstreamCommit: "fedcba9876543210fedcba9876543210fedcba98",
            bundleURL: URL(fileURLWithPath: "/tmp/VoiceInk.app"),
            preparedAt: Date(timeIntervalSince1970: 1_787_400_000)
        )

        adapter.send(.stagedCandidate(candidate))
        adapter.send(.preparationFailed("VoiceInk could not read credentials."))

        #expect(updater.state.stagedUpdate == nil)
        #expect(!updater.state.isPresentingStagedUpdate)
        #expect(updater.state.preparationError == "VoiceInk could not read credentials.")
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
    func restartCreatesThePreQuitCredentialGenerationBeforeStartingTheInstaller() async throws {
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
        let candidate = StagedForkCandidate(
            forkCommit: "1111111111111111111111111111111111111111",
            upstreamCommit: "2222222222222222222222222222222222222222",
            bundleURL: temporaryDirectory.appendingPathComponent("VoiceInk.app"),
            preparedAt: Date(timeIntervalSince1970: 1_787_400_400)
        )
        try PropertyListEncoder().encode(candidate).write(to: manifestURL, options: .atomic)
        let recorder = ForkUpdateRestartRecorder()
        let credentialStore = ForkUpdateCredentialRestorerStub(recorder: recorder)
        let transaction = ForkUpdateTransaction(
            scriptURL: temporaryDirectory.appendingPathComponent("prepare-local-update.sh"),
            manifestURL: manifestURL,
            installationScriptURL: temporaryDirectory.appendingPathComponent("install-local-update.sh"),
            targetBundleURL: installedBundle,
            backupBundleURL: temporaryDirectory.appendingPathComponent("Recovery/VoiceInk.app"),
            credentialSnapshotter: credentialStore,
            installationRunner: ForkUpdateInstallationRunnerStub(recorder: recorder)
        )

        _ = try await transaction.requestRestart(for: candidate)

        #expect(recorder.events == [.credentialsSnapshotted, .installerStarted])
        #expect(credentialStore.createdGenerations.count == 1)
        let recoveryIntent = temporaryDirectory.appendingPathComponent("Recovery.pending/recovery.plist")
        let intent = try PropertyListDecoder().decode(
            LocalUpdateRecoveryState.self,
            from: Data(contentsOf: recoveryIntent)
        )
        #expect(intent.installInProgress == true)
        #expect(intent.credentialGeneration == credentialStore.createdGenerations[0])
        #expect(!FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent("Recovery.preparing").path))
    }

    @Test
    func credentialSnapshotQueryReadsAServiceWithLocalCredentials() throws {
        let persistence = SecurityLocalUpdateCredentialPersistence()
        let service = "UpdaterViewModelTests.credentials.\(UUID().uuidString)"
        let account = "candidate"
        let data = Data("secret".utf8)
        defer { try? persistence.delete(account: account, service: service) }

        try persistence.write(data, account: account, service: service, accessibility: nil)

        let records = try persistence.readRecords(service: service)

        #expect(records.map(\.account) == [account])
        #expect(records.map(\.data) == [data])
    }

    @Test
    func restartRemovesTheIntentWhenCredentialSnapshotCreationFails() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let credentialStore = FailingForkUpdateCredentialStore()
        let fixture = try makeRestartTransactionFixture(
            at: temporaryDirectory,
            credentialStore: credentialStore,
            installationRunner: ForkUpdateInstallationRunnerStub(recorder: ForkUpdateRestartRecorder())
        )

        do {
            _ = try await fixture.transaction.requestRestart(for: fixture.candidate)
            Issue.record("Expected credential snapshot creation to fail")
        } catch {
            #expect(error.localizedDescription == "Injected credential snapshot failure.")
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.pendingRecovery.path))
    }

    @Test
    func installerFailureIsNotMaskedWhenTheHelperAlreadyRemovedTheIntent() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let credentialStore = ForkUpdateCredentialRestorerStub()
        let fixture = try makeRestartTransactionFixture(
            at: temporaryDirectory,
            credentialStore: credentialStore,
            installationRunner: PrecleaningFailureInstallationRunner()
        )

        do {
            _ = try await fixture.transaction.requestRestart(for: fixture.candidate)
            Issue.record("Expected installation to fail")
        } catch {
            #expect(error.localizedDescription == "Injected installer failure.")
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.pendingRecovery.path))
        #expect(credentialStore.deletedGenerations.count == 1)
    }

    @Test
    func recoveryCommandRestoresTheKeychainSnapshotWithoutStartingTheApp() throws {
        let credentialStore = ForkUpdateCredentialRestorerStub()
        let generation = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"

        let handled = try LocalUpdateCredentialRecoveryCommand.runIfRequested(
            arguments: ["VoiceInk", "--voiceink-restore-update-credentials", generation],
            credentialStore: credentialStore
        )

        #expect(handled)
        #expect(credentialStore.restoredGenerations == [generation.lowercased()])
    }

    @Test
    func recoveryCommandCreatesAGenerationBoundKeychainSnapshotWithoutStartingTheApp() throws {
        let credentialStore = ForkUpdateCredentialRestorerStub()
        let generation = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        let handled = try LocalUpdateCredentialRecoveryCommand.runIfRequested(
            arguments: ["VoiceInk", "--voiceink-create-update-credentials", generation],
            credentialStore: credentialStore
        )

        #expect(handled)
        #expect(credentialStore.createdGenerations == [generation.lowercased()])
    }

    @Test
    func credentialRestoreCompensatesAPartialKeychainReplacement() throws {
        let rejectedRecord = LocalUpdateCredentialRecord(
            account: "candidate",
            data: Data("candidate-token".utf8),
            accessibility: nil
        )
        let restoredRecords = [
            LocalUpdateCredentialRecord(account: "previous-a", data: Data("a".utf8), accessibility: nil),
            LocalUpdateCredentialRecord(account: "previous-b", data: Data("b".utf8), accessibility: nil),
        ]
        let persistence = LocalUpdateCredentialPersistenceStub(
            currentRecords: [rejectedRecord],
            snapshotRecords: restoredRecords,
            remainingWriteFailures: ["previous-b": 1]
        )

        var restorationFailed = false
        do {
            try LocalUpdateCredentialSnapshotStore(persistence: persistence)
                .restoreSnapshot(generationIdentifier: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        } catch {
            restorationFailed = true
        }

        #expect(restorationFailed)
        #expect(persistence.currentRecords == [rejectedRecord])
    }

    @Test
    func credentialRestoreReportsWhenKeychainCompensationAlsoFails() throws {
        let rejectedRecord = LocalUpdateCredentialRecord(
            account: "candidate",
            data: Data("candidate-token".utf8),
            accessibility: nil
        )
        let restoredRecords = [
            LocalUpdateCredentialRecord(account: "previous-a", data: Data("a".utf8), accessibility: nil),
            LocalUpdateCredentialRecord(account: "previous-b", data: Data("b".utf8), accessibility: nil),
        ]
        let persistence = LocalUpdateCredentialPersistenceStub(
            currentRecords: [rejectedRecord],
            snapshotRecords: restoredRecords,
            remainingWriteFailures: ["previous-b": 1, "candidate": 1]
        )

        do {
            try LocalUpdateCredentialSnapshotStore(persistence: persistence)
                .restoreSnapshot(generationIdentifier: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
            Issue.record("Expected credential restoration to fail")
        } catch {
            #expect(
                error.localizedDescription
                    == "VoiceInk could not restore credentials or compensate the partial Keychain update."
            )
        }
    }

    @Test
    func launchFinishesPublishingTheRecoveryGenerationThatMatchesTheInstalledCandidate() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let installedBundle = temporaryDirectory.appendingPathComponent("VoiceInk.app", isDirectory: true)
        let recoveryRoot = temporaryDirectory.appendingPathComponent("Recovery", isDirectory: true)
        let pendingRecovery = URL(fileURLWithPath: recoveryRoot.path + ".pending", isDirectory: true)
        let installedCommit = "1111111111111111111111111111111111111111"
        let previousCommit = "2222222222222222222222222222222222222222"
        let currentGeneration = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let pendingGeneration = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try FileManager.default.createDirectory(
            at: installedBundle.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(
            fromPropertyList: [SourceProvenance.forkCommitInfoKey: installedCommit],
            format: .xml,
            options: 0
        ).write(to: installedBundle.appendingPathComponent("Contents/Info.plist"))
        try writeRecoveryState(
            LocalUpdateRecoveryState(
                previousForkCommit: "3333333333333333333333333333333333333333",
                candidateForkCommit: previousCommit,
                credentialGeneration: currentGeneration,
                suppressedForkCommit: nil,
                installInProgress: false,
                restoreInProgress: false
            ),
            marker: "current",
            at: recoveryRoot
        )
        try writeRecoveryState(
            LocalUpdateRecoveryState(
                previousForkCommit: previousCommit,
                candidateForkCommit: installedCommit,
                credentialGeneration: pendingGeneration,
                suppressedForkCommit: nil,
                installInProgress: false,
                restoreInProgress: false
            ),
            marker: "pending",
            at: pendingRecovery
        )
        let credentialStore = ForkUpdateCredentialRestorerStub()

        try LocalUpdateRecoveryReconciler(credentialStore: credentialStore).reconcile(
            installedBundleURL: installedBundle,
            recoveryRootURL: recoveryRoot
        )

        #expect(try String(contentsOf: recoveryRoot.appendingPathComponent("marker"), encoding: .utf8) == "pending")
        #expect(!FileManager.default.fileExists(atPath: pendingRecovery.path))
        #expect(!FileManager.default.fileExists(atPath: recoveryRoot.path + ".previous"))
        #expect(credentialStore.deletedGenerations == [currentGeneration])
    }

    @Test
    func launchDiscardsAnInstallIntentWhenBundleReplacementNeverStarted() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let installedBundle = temporaryDirectory.appendingPathComponent("VoiceInk.app", isDirectory: true)
        let recoveryRoot = temporaryDirectory.appendingPathComponent("Recovery", isDirectory: true)
        let pendingRecovery = URL(fileURLWithPath: recoveryRoot.path + ".pending", isDirectory: true)
        let installedCommit = "1111111111111111111111111111111111111111"
        let generation = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try FileManager.default.createDirectory(
            at: installedBundle.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(
            fromPropertyList: [SourceProvenance.forkCommitInfoKey: installedCommit],
            format: .xml,
            options: 0
        ).write(to: installedBundle.appendingPathComponent("Contents/Info.plist"))
        try writeRecoveryState(
            LocalUpdateRecoveryState(
                previousForkCommit: installedCommit,
                candidateForkCommit: "2222222222222222222222222222222222222222",
                credentialGeneration: generation,
                suppressedForkCommit: nil,
                installInProgress: true,
                restoreInProgress: false
            ),
            marker: "intent",
            at: pendingRecovery
        )
        let credentialStore = ForkUpdateCredentialRestorerStub()

        try LocalUpdateRecoveryReconciler(credentialStore: credentialStore).reconcile(
            installedBundleURL: installedBundle,
            recoveryRootURL: recoveryRoot
        )

        #expect(!FileManager.default.fileExists(atPath: pendingRecovery.path))
        #expect(credentialStore.deletedGenerations == [generation])
    }

    @Test
    func launchDiscardsAnInterruptedIntentPreparationWithoutReadingBundleState() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recoveryRoot = temporaryDirectory.appendingPathComponent("Recovery", isDirectory: true)
        let preparingRecovery = URL(fileURLWithPath: recoveryRoot.path + ".preparing", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: preparingRecovery, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: preparingRecovery.appendingPathComponent("recovery.plist"))

        try LocalUpdateRecoveryReconciler().reconcile(
            installedBundleURL: temporaryDirectory.appendingPathComponent("Missing.app"),
            recoveryRootURL: recoveryRoot
        )

        #expect(!FileManager.default.fileExists(atPath: preparingRecovery.path))
    }

    @Test
    func launchRejectsMalformedRecoveryMetadata() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let installedBundle = temporaryDirectory.appendingPathComponent("VoiceInk.app", isDirectory: true)
        let pendingRecovery = temporaryDirectory.appendingPathComponent("Recovery.pending", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: pendingRecovery, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: installedBundle.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(
            fromPropertyList: [
                SourceProvenance.forkCommitInfoKey: "1111111111111111111111111111111111111111",
            ],
            format: .xml,
            options: 0
        ).write(to: installedBundle.appendingPathComponent("Contents/Info.plist"))

        do {
            try LocalUpdateRecoveryReconciler().reconcile(
                installedBundleURL: installedBundle,
                recoveryRootURL: temporaryDirectory.appendingPathComponent("Recovery")
            )
            Issue.record("Expected malformed recovery metadata to stop launch")
        } catch {
            #expect(error.localizedDescription.contains("without valid metadata"))
        }
    }

    @Test
    func launchRecoversPreviousWhenPublicationMovedTheCurrentGenerationAside() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let installedBundle = temporaryDirectory.appendingPathComponent("VoiceInk.app", isDirectory: true)
        let recoveryRoot = temporaryDirectory.appendingPathComponent("Recovery", isDirectory: true)
        let previousRecovery = URL(fileURLWithPath: recoveryRoot.path + ".previous", isDirectory: true)
        let installedCommit = "1111111111111111111111111111111111111111"
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(
            at: installedBundle.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(
            fromPropertyList: [SourceProvenance.forkCommitInfoKey: installedCommit],
            format: .xml,
            options: 0
        ).write(to: installedBundle.appendingPathComponent("Contents/Info.plist"))
        try writeRecoveryState(
            LocalUpdateRecoveryState(
                previousForkCommit: "2222222222222222222222222222222222222222",
                candidateForkCommit: "3333333333333333333333333333333333333333",
                credentialGeneration: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                suppressedForkCommit: nil,
                installInProgress: false,
                restoreInProgress: false
            ),
            marker: "superseded",
            at: recoveryRoot
        )
        try writeRecoveryState(
            LocalUpdateRecoveryState(
                previousForkCommit: "4444444444444444444444444444444444444444",
                candidateForkCommit: installedCommit,
                credentialGeneration: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                suppressedForkCommit: nil,
                installInProgress: false,
                restoreInProgress: false
            ),
            marker: "previous",
            at: previousRecovery
        )
        let credentialStore = ForkUpdateCredentialRestorerStub()

        try LocalUpdateRecoveryReconciler(credentialStore: credentialStore).reconcile(
            installedBundleURL: installedBundle,
            recoveryRootURL: recoveryRoot
        )

        #expect(try String(contentsOf: recoveryRoot.appendingPathComponent("marker"), encoding: .utf8) == "previous")
        #expect(!FileManager.default.fileExists(atPath: previousRecovery.path))
        #expect(credentialStore.deletedGenerations == ["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"])
    }

    @Test
    func launchRejectsRecoveryGenerationsThatDoNotMatchTheInstalledBundle() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let installedBundle = temporaryDirectory.appendingPathComponent("VoiceInk.app", isDirectory: true)
        let recoveryRoot = temporaryDirectory.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(
            at: installedBundle.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(
            fromPropertyList: [
                SourceProvenance.forkCommitInfoKey: "1111111111111111111111111111111111111111",
            ],
            format: .xml,
            options: 0
        ).write(to: installedBundle.appendingPathComponent("Contents/Info.plist"))
        try writeRecoveryState(
            LocalUpdateRecoveryState(
                previousForkCommit: "2222222222222222222222222222222222222222",
                candidateForkCommit: "3333333333333333333333333333333333333333",
                credentialGeneration: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                suppressedForkCommit: nil,
                installInProgress: false,
                restoreInProgress: false
            ),
            marker: "mismatch",
            at: recoveryRoot
        )

        do {
            try LocalUpdateRecoveryReconciler().reconcile(
                installedBundleURL: installedBundle,
                recoveryRootURL: recoveryRoot
            )
            Issue.record("Expected mismatched recovery generations to stop launch")
        } catch {
            #expect(error.localizedDescription.contains("does not match the installed app"))
        }
    }

    @Test
    func launchResumesAnInterruptedInstallBeforeRecoveryReconciliation() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let installedBundle = temporaryDirectory.appendingPathComponent("VoiceInk.app", isDirectory: true)
        let recoveryRoot = temporaryDirectory.appendingPathComponent("Recovery", isDirectory: true)
        let pendingRecovery = URL(fileURLWithPath: recoveryRoot.path + ".pending", isDirectory: true)
        let recoveryBundle = pendingRecovery.appendingPathComponent("VoiceInk.app", isDirectory: true)
        let scriptURL = temporaryDirectory.appendingPathComponent("restore-local-update.sh")
        let resumedMarker = temporaryDirectory.appendingPathComponent("resumed")
        let installedCommit = "1111111111111111111111111111111111111111"
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try FileManager.default.createDirectory(
            at: installedBundle.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(
            fromPropertyList: [SourceProvenance.forkCommitInfoKey: installedCommit],
            format: .xml,
            options: 0
        ).write(to: installedBundle.appendingPathComponent("Contents/Info.plist"))
        try writeRecoveryState(
            LocalUpdateRecoveryState(
                previousForkCommit: "2222222222222222222222222222222222222222",
                candidateForkCommit: installedCommit,
                credentialGeneration: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                suppressedForkCommit: nil,
                installInProgress: true,
                restoreInProgress: false
            ),
            marker: "pending",
            at: pendingRecovery
        )
        try FileManager.default.createDirectory(at: recoveryBundle, withIntermediateDirectories: true)
        let script = """
        #!/usr/bin/env bash
        [[ "$1" == "--resume" && -d "$2" && -d "$3" ]] || exit 1
        /usr/bin/touch "\(resumedMarker.path)"
        """
        try Data(script.utf8).write(to: scriptURL)

        let resumed = try LocalUpdateRestoreResumer().resumeIfNeeded(
            installedBundleURL: installedBundle,
            recoveryRootURL: recoveryRoot,
            restorationScriptURL: scriptURL
        )

        #expect(resumed)
        #expect(FileManager.default.fileExists(atPath: resumedMarker.path))
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
                candidateForkCommit: candidateCommit,
                credentialGeneration: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                suppressedForkCommit: nil,
                installInProgress: false,
                restoreInProgress: false
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

        #expect(
            LocalUpdateHealthReporter.isRequested(
                arguments: ["VoiceInk", "--voiceink-update-health-path", healthURL.path]
            )
        )
        #expect(!LocalUpdateHealthReporter.isRequested(arguments: ["VoiceInk"]))
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

private final class ForkUpdateCredentialRestorerStub:
    ForkUpdateCredentialSnapshotting,
    ForkUpdateCredentialRestoring,
    @unchecked Sendable
{
    private let recorder: ForkUpdateRestartRecorder?
    private(set) var createdGenerations: [String] = []
    private(set) var deletedGenerations: [String] = []
    private(set) var restoredGenerations: [String] = []

    init(recorder: ForkUpdateRestartRecorder? = nil) {
        self.recorder = recorder
    }

    func createSnapshot(generationIdentifier: String) throws {
        createdGenerations.append(generationIdentifier)
        recorder?.events.append(.credentialsSnapshotted)
    }

    func deleteSnapshot(generationIdentifier: String) throws {
        deletedGenerations.append(generationIdentifier)
    }

    func restoreSnapshot(generationIdentifier: String) throws {
        restoredGenerations.append(generationIdentifier)
    }
}

private final class LocalUpdateCredentialPersistenceStub: LocalUpdateCredentialPersisting {
    private(set) var currentRecords: [LocalUpdateCredentialRecord]
    private let snapshotData: Data
    private var remainingWriteFailures: [String: Int]

    init(
        currentRecords: [LocalUpdateCredentialRecord],
        snapshotRecords: [LocalUpdateCredentialRecord],
        remainingWriteFailures: [String: Int]
    ) {
        self.currentRecords = currentRecords
        snapshotData = try! PropertyListEncoder().encode(snapshotRecords)
        self.remainingWriteFailures = remainingWriteFailures
    }

    func readRecords(service: String) throws -> [LocalUpdateCredentialRecord] {
        currentRecords
    }

    func read(account: String, service: String) throws -> Data {
        snapshotData
    }

    func write(_ data: Data, account: String, service: String, accessibility: String?) throws {
        if let remaining = remainingWriteFailures[account], remaining > 0 {
            remainingWriteFailures[account] = remaining - 1
            throw ForkUpdateError(message: "Injected Keychain write failure for \(account).")
        }
        let record = LocalUpdateCredentialRecord(account: account, data: data, accessibility: accessibility)
        currentRecords.removeAll { $0.account == account }
        currentRecords.append(record)
    }

    func delete(account: String, service: String) throws {
        currentRecords.removeAll { $0.account == account }
    }
}

private func writeRecoveryState(
    _ state: LocalUpdateRecoveryState,
    marker: String,
    at directory: URL
) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try PropertyListEncoder().encode(state).write(
        to: directory.appendingPathComponent("recovery.plist"),
        options: .atomic
    )
    try Data(marker.utf8).write(to: directory.appendingPathComponent("marker"))
}

private struct ForkUpdateInstallationRunnerStub: ForkUpdateInstalling {
    let recorder: ForkUpdateRestartRecorder

    func install(_ request: ForkUpdateInstallationRequest) async throws -> ForkUpdateInstallationOutcome {
        recorder.events.append(.installerStarted)
        return .completed
    }
}

private final class FailingForkUpdateCredentialStore:
    ForkUpdateCredentialSnapshotting,
    ForkUpdateCredentialRestoring
{
    func createSnapshot(generationIdentifier: String) throws {
        throw ForkUpdateError(message: "Injected credential snapshot failure.")
    }

    func deleteSnapshot(generationIdentifier: String) throws {}
    func restoreSnapshot(generationIdentifier: String) throws {}
}

private struct PrecleaningFailureInstallationRunner: ForkUpdateInstalling {
    func install(_ request: ForkUpdateInstallationRequest) async throws -> ForkUpdateInstallationOutcome {
        let pendingRecovery = URL(
            fileURLWithPath: request.backupBundleURL.deletingLastPathComponent().path + ".pending",
            isDirectory: true
        )
        try FileManager.default.removeItem(at: pendingRecovery)
        throw ForkUpdateError(message: "Injected installer failure.")
    }
}

@MainActor
private func makeRestartTransactionFixture(
    at temporaryDirectory: URL,
    credentialStore: any ForkUpdateCredentialSnapshotting,
    installationRunner: any ForkUpdateInstalling
) throws -> (
    transaction: ForkUpdateTransaction,
    candidate: StagedForkCandidate,
    pendingRecovery: URL
) {
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
    let candidate = StagedForkCandidate(
        forkCommit: "1111111111111111111111111111111111111111",
        upstreamCommit: "2222222222222222222222222222222222222222",
        bundleURL: temporaryDirectory.appendingPathComponent("VoiceInk.app"),
        preparedAt: Date(timeIntervalSince1970: 1_787_400_400)
    )
    try PropertyListEncoder().encode(candidate).write(to: manifestURL, options: .atomic)
    let backupBundle = temporaryDirectory.appendingPathComponent("Recovery/VoiceInk.app")
    let transaction = ForkUpdateTransaction(
        scriptURL: temporaryDirectory.appendingPathComponent("prepare-local-update.sh"),
        manifestURL: manifestURL,
        installationScriptURL: temporaryDirectory.appendingPathComponent("install-local-update.sh"),
        targetBundleURL: installedBundle,
        backupBundleURL: backupBundle,
        credentialSnapshotter: credentialStore,
        installationRunner: installationRunner
    )
    return (
        transaction,
        candidate,
        URL(fileURLWithPath: backupBundle.deletingLastPathComponent().path + ".pending", isDirectory: true)
    )
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
