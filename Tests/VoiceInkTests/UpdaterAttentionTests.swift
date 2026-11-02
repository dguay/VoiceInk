import Foundation
import Testing
@testable import VoiceInk

@MainActor
struct UpdaterAttentionTests {
    private static let forkCommit = "0123456789abcdef0123456789abcdef01234567"
    private static let upstreamCommit = "fedcba9876543210fedcba9876543210fedcba98"

    @Test
    func deterministicFailureNeedsAttentionUntilItClears() {
        let fixture = Fixture(suiteName: "UpdaterAttentionTests.attention")
        defer { fixture.tearDown() }

        #expect(!fixture.updater.state.needsAttention)

        fixture.adapter.send(.preparationFailed(Self.mergeFailure()))
        #expect(fixture.updater.state.needsAttention)

        fixture.adapter.send(.failedAttemptCleared)
        #expect(!fixture.updater.state.needsAttention)

        fixture.adapter.send(
            .preparationFailed(
                .reported(
                    stage: .fetch,
                    kind: .transient,
                    candidateIdentifier: nil,
                    message: "VoiceInk could not reach an update dependency."
                )
            )
        )
        #expect(!fixture.updater.state.needsAttention)
    }

    @Test
    func attentionItemOpensUpdateSettingsInTheMainWindow() {
        let fixture = Fixture(suiteName: "UpdaterAttentionTests.open-settings")
        defer { fixture.tearDown() }
        fixture.adapter.send(.preparationFailed(Self.mergeFailure()))

        fixture.updater.showUpdateSettings()

        #expect(fixture.presenter.events == [.updateSettings])
    }

    @Test
    func mergeFailureExposesStageConflictsAndRepository() {
        let fixture = Fixture(suiteName: "UpdaterAttentionTests.merge-failure")
        defer { fixture.tearDown() }
        let failure = Self.mergeFailure()

        fixture.adapter.send(.preparationFailed(failure))
        fixture.updater.openUpdateRepository()

        #expect(failure.stage.displayName == "Merge")
        #expect(fixture.updater.state.failure?.conflictedFiles == ["README.md", "VoiceInk/App.swift"])
        let repositoryURL = URL(fileURLWithPath: "/tmp/VoiceInk-clone", isDirectory: true)
        #expect(fixture.updater.state.failure?.repositoryURL == repositoryURL)
        #expect(fixture.repositoryOpener.openedURLs == [repositoryURL])
    }

    @Test
    func failureWithoutRepositoryHasNoRepositoryAction() {
        let fixture = Fixture(suiteName: "UpdaterAttentionTests.no-repository")
        defer { fixture.tearDown() }
        let failure = ForkUpdateFailure.reported(
            stage: .build,
            kind: .deterministic,
            candidateIdentifier: "candidate",
            message: "The candidate failed to build."
        )

        fixture.adapter.send(.preparationFailed(failure))
        fixture.updater.openUpdateRepository()

        #expect(fixture.updater.state.failure?.repositoryURL == nil)
        #expect(fixture.updater.state.failure?.conflictedFiles == [])
        #expect(fixture.repositoryOpener.openedURLs.isEmpty)
    }

    @Test
    func candidateNotificationBringsTheMainWindowForwardAndPresentsTheAlert() throws {
        let fixture = Fixture(suiteName: "UpdaterAttentionTests.view-action")
        defer { fixture.tearDown() }

        fixture.adapter.send(.stagedCandidate(Self.candidate()))
        fixture.updater.deferStagedUpdate()
        #expect(!fixture.updater.state.isPresentingStagedUpdate)
        let delivery = try #require(fixture.notifications.deliveries.last)
        #expect(delivery.notification.actionLabel == "View")

        delivery.action()

        #expect(fixture.presenter.events == [.mainWindow])
        #expect(fixture.updater.state.isPresentingStagedUpdate)
    }

    @Test
    func failureNotificationActionsBringUpdateSettingsForward() throws {
        let fixture = Fixture(suiteName: "UpdaterAttentionTests.failure-actions")
        defer { fixture.tearDown() }

        fixture.adapter.send(.preparationFailed(Self.mergeFailure()))
        let copyDelivery = try #require(fixture.notifications.deliveries.last)
        #expect(copyDelivery.notification.actionLabel == "Copy fix update prompt")
        copyDelivery.action()
        #expect(fixture.promptCopier.copiedPrompts.count == 1)
        #expect(fixture.presenter.events == [.updateSettings])

        fixture.adapter.send(
            .preparationFailed(
                .reported(
                    stage: .build,
                    kind: .deterministic,
                    candidateIdentifier: "other",
                    message: "The candidate failed to build."
                )
            )
        )
        let logsDelivery = try #require(fixture.notifications.deliveries.last)
        #expect(logsDelivery.notification.actionLabel == "Open Logs")
        logsDelivery.action()
        #expect(fixture.logOpener.openCount == 1)
        #expect(fixture.presenter.events == [.updateSettings, .updateSettings])

        fixture.adapter.send(.rollbackCompleted)
        let rollbackDelivery = try #require(fixture.notifications.deliveries.last)
        #expect(rollbackDelivery.notification.actionLabel == "Open Logs")
        rollbackDelivery.action()
        #expect(fixture.logOpener.openCount == 2)
        #expect(fixture.presenter.events == [.updateSettings, .updateSettings, .updateSettings])
    }

    @Test
    func summaryRendersCommitCountSubjectsAndCandidateAge() {
        let preparedAt = Date(timeIntervalSince1970: 1_787_400_000)
        let candidate = Self.candidate(
            preparedAt: preparedAt,
            changeSummary: StagedForkChangeSummary(
                upstreamCommitCount: 7,
                upstreamCommitSubjects: ["feat: one", "fix: two", "chore: three"]
            )
        )

        let presentation = StagedUpdatePresentation(
            candidate: candidate,
            now: preparedAt.addingTimeInterval(2 * 60 * 60 + 5),
            maximumSubjects: 2
        )

        #expect(presentation.headline == "7 upstream commits since the installed version")
        #expect(presentation.subjects == ["feat: one", "fix: two"])
        #expect(presentation.additionalCommitCount == 5)
        #expect(presentation.age == "Prepared 2 hours ago")
        #expect(
            presentation.message
                == """
                VoiceInk prepared fork commit 0123456789ab 2 hours ago.

                7 upstream commits since the installed version:
                • feat: one
                • fix: two
                …and 5 more
                """
        )
    }

    @Test
    func summaryBoundsLongSubjects() {
        let longSubject = "feat: " + String(repeating: "é", count: 200)
        let presentation = StagedUpdatePresentation(
            candidate: Self.candidate(
                changeSummary: StagedForkChangeSummary(
                    upstreamCommitCount: 1,
                    upstreamCommitSubjects: [longSubject]
                )
            )
        )

        #expect(presentation.subjects.first?.count == StagedUpdatePresentation.maximumSubjectLength)
        #expect(presentation.subjects.first?.hasSuffix("…") == true)
        #expect(presentation.subjects.first?.hasPrefix("feat: é") == true)
    }

    @Test
    func candidateWithoutSummaryStillDecodesAndRenders() throws {
        let preparedAt = Date(timeIntervalSince1970: 1_787_400_000)
        let legacyManifest: [String: Any] = [
            "forkCommit": Self.forkCommit,
            "upstreamCommit": Self.upstreamCommit,
            "bundlePath": "/tmp/VoiceInk.app",
            "preparedAt": preparedAt,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: legacyManifest,
            format: .xml,
            options: 0
        )

        let candidate = try PropertyListDecoder().decode(StagedForkCandidate.self, from: data)
        let presentation = StagedUpdatePresentation(
            candidate: candidate,
            now: preparedAt.addingTimeInterval(30)
        )

        #expect(candidate.changeSummary == nil)
        #expect(presentation.headline == nil)
        #expect(presentation.subjects.isEmpty)
        #expect(presentation.age == "Prepared just now")
        #expect(presentation.message == "VoiceInk prepared fork commit 0123456789ab just now.")
    }

    @Test
    func manifestSummaryWrittenByPreparationDecodes() throws {
        let manifest: [String: Any] = [
            "forkCommit": Self.forkCommit,
            "upstreamCommit": Self.upstreamCommit,
            "bundlePath": "/tmp/VoiceInk.app",
            "preparedAt": Date(timeIntervalSince1970: 1_787_400_000),
            "changeSummary": [
                "upstreamCommitCount": 1,
                "upstreamCommitSubjects": ["feat: advance upstream"],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)

        let candidate = try PropertyListDecoder().decode(StagedForkCandidate.self, from: data)
        let presentation = StagedUpdatePresentation(
            candidate: candidate,
            now: Date(timeIntervalSince1970: 1_787_400_000 + 3 * 24 * 60 * 60)
        )

        #expect(
            candidate.changeSummary
                == StagedForkChangeSummary(
                    upstreamCommitCount: 1,
                    upstreamCommitSubjects: ["feat: advance upstream"]
                )
        )
        #expect(presentation.headline == "1 upstream commit since the installed version")
        #expect(presentation.additionalCommitCount == 0)
        #expect(presentation.age == "Prepared 3 days ago")

        let roundTrip = try PropertyListDecoder().decode(
            StagedForkCandidate.self,
            from: PropertyListEncoder().encode(candidate)
        )
        #expect(roundTrip == candidate)
    }

    @Test
    func installedSourceExposesShortSHAsCompareLinkAndCheckTimes() {
        let lastCheck = Date(timeIntervalSince1970: 1_787_400_000)
        let fixture = Fixture(
            suiteName: "UpdaterAttentionTests.provenance",
            lastUpdateCheckDate: lastCheck,
            updateCheckInterval: 24 * 60 * 60
        )
        defer { fixture.tearDown() }
        let provenance = SourceProvenance(forkCommit: Self.forkCommit, upstreamCommit: Self.upstreamCommit)

        #expect(provenance.shortForkCommit == "0123456789ab")
        #expect(provenance.shortUpstreamCommit == "fedcba987654")
        #expect(
            provenance.upstreamCompareURL.absoluteString
                == "https://github.com/Beingpax/VoiceInk/compare/\(Self.upstreamCommit)...main"
        )
        #expect(fixture.updater.state.lastUpdateCheckDate == lastCheck)
        #expect(
            fixture.updater.state.nextAutomaticUpdateCheckDate
                == lastCheck.addingTimeInterval(24 * 60 * 60)
        )

        fixture.updater.setChecksForUpdatesWhenDashboardAppears(false)
        #expect(fixture.updater.state.nextAutomaticUpdateCheckDate == nil)

        let completedAt = lastCheck.addingTimeInterval(60)
        fixture.updater.setChecksForUpdatesWhenDashboardAppears(true)
        fixture.adapter.state = UpdaterAdapterState(
            canCheckForUpdates: true,
            sessionInProgress: false,
            lastUpdateCheckDate: completedAt,
            updateCheckInterval: 24 * 60 * 60
        )
        fixture.adapter.send(.stateChanged(fixture.adapter.state))
        #expect(fixture.updater.state.lastUpdateCheckDate == completedAt)
        #expect(
            fixture.updater.state.nextAutomaticUpdateCheckDate
                == completedAt.addingTimeInterval(24 * 60 * 60)
        )
    }

    private static func candidate(
        preparedAt: Date = Date(timeIntervalSince1970: 1_787_400_000),
        changeSummary: StagedForkChangeSummary? = nil
    ) -> StagedForkCandidate {
        StagedForkCandidate(
            forkCommit: forkCommit,
            upstreamCommit: upstreamCommit,
            bundleURL: URL(fileURLWithPath: "/tmp/VoiceInk.app"),
            preparedAt: preparedAt,
            changeSummary: changeSummary
        )
    }

    private static func mergeFailure() -> ForkUpdateFailure {
        ForkUpdateFailure.reported(
            stage: .merge,
            kind: .deterministic,
            candidateIdentifier: "\(forkCommit):\(upstreamCommit)",
            message: "The fetched fork conflicts with upstream/main. Resolve the shared fork before retrying.",
            attemptContext: ForkUpdateAttemptContext(
                attemptIdentifier: "attempt-1",
                repositoryPath: "/tmp/VoiceInk-clone",
                originRepository: "https://github.com/example/VoiceInk.git",
                upstreamRepository: "https://github.com/Beingpax/VoiceInk.git",
                installedForkCommit: nil,
                forkCommit: forkCommit,
                upstreamCommit: upstreamCommit,
                stage: .merge,
                conflicts: ["README.md", "VoiceInk/App.swift"],
                logs: []
            )
        )
    }
}

@MainActor
private struct Fixture {
    let suiteName: String
    let defaults: UserDefaults
    let adapter: AttentionUpdaterAdapterStub
    let notifications: AttentionNotificationRecorder
    let logOpener: AttentionLogOpenerRecorder
    let presenter: UpdaterWindowPresenterRecorder
    let repositoryOpener: RepositoryOpenerRecorder
    let promptCopier: AttentionPromptCopierRecorder
    let updater: UpdaterViewModel

    init(
        suiteName: String,
        lastUpdateCheckDate: Date? = nil,
        updateCheckInterval: TimeInterval = 24 * 60 * 60
    ) {
        self.suiteName = suiteName
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        adapter = AttentionUpdaterAdapterStub(
            lastUpdateCheckDate: lastUpdateCheckDate,
            updateCheckInterval: updateCheckInterval
        )
        notifications = AttentionNotificationRecorder()
        logOpener = AttentionLogOpenerRecorder()
        presenter = UpdaterWindowPresenterRecorder()
        repositoryOpener = RepositoryOpenerRecorder()
        promptCopier = AttentionPromptCopierRecorder()
        updater = UpdaterViewModel(
            defaults: defaults,
            adapter: adapter,
            sourceProvenance: nil,
            notificationDeliverer: notifications,
            logOpener: logOpener,
            contextStore: ForkUpdateAttemptContextStore(
                directoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(suiteName, isDirectory: true)
            ),
            promptCopier: promptCopier,
            applicationExecutableURL: nil,
            windowPresenter: presenter,
            repositoryOpener: repositoryOpener
        )
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class AttentionUpdaterAdapterStub: UpdaterAdapter {
    var state: UpdaterAdapterState
    var onEvent: ((UpdaterAdapterEvent) -> Void)?

    init(lastUpdateCheckDate: Date?, updateCheckInterval: TimeInterval) {
        state = UpdaterAdapterState(
            canCheckForUpdates: true,
            sessionInProgress: false,
            lastUpdateCheckDate: lastUpdateCheckDate,
            updateCheckInterval: updateCheckInterval
        )
    }

    func start() {}
    func checkForUpdateInformation() {}
    func checkForUpdates() {}
    func send(_ event: UpdaterAdapterEvent) { onEvent?(event) }
}

@MainActor
private final class AttentionNotificationRecorder: ForkUpdateNotificationDelivering {
    struct Delivery {
        let notification: ForkUpdateUserNotification
        let action: () -> Void
    }

    private(set) var deliveries: [Delivery] = []

    func deliver(_ notification: ForkUpdateUserNotification, action: @escaping () -> Void) {
        deliveries.append(Delivery(notification: notification, action: action))
    }
}

@MainActor
private final class AttentionLogOpenerRecorder: ForkUpdateLogOpening {
    private(set) var openCount = 0

    func openLogs() {
        openCount += 1
    }
}

@MainActor
private final class UpdaterWindowPresenterRecorder: UpdaterWindowPresenting {
    enum Event: Equatable {
        case mainWindow
        case updateSettings
    }

    private(set) var events: [Event] = []

    func showMainWindow() {
        events.append(.mainWindow)
    }

    func showUpdateSettings() {
        events.append(.updateSettings)
    }
}

@MainActor
private final class RepositoryOpenerRecorder: ForkUpdateRepositoryOpening {
    private(set) var openedURLs: [URL] = []

    func openRepository(at url: URL) {
        openedURLs.append(url)
    }
}

@MainActor
private final class AttentionPromptCopierRecorder: ForkUpdatePromptCopying {
    private(set) var copiedPrompts: [String] = []

    func copy(_ prompt: String) throws {
        copiedPrompts.append(prompt)
    }
}
