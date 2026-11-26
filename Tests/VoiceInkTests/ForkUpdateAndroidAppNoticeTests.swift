import Foundation
import Testing
@testable import VoiceInk

/// The preparation helper records in the staged manifest why a candidate bundles
/// no new Android keyboard APK. The notice never blocks the Mac update: the
/// candidate is staged as usual, the notice is logged with the staging record,
/// shown with the update, and announced once.
@Suite(.serialized)
struct ForkUpdateAndroidAppNoticeTests {
    static let forkCommit = "0123456789abcdef0123456789abcdef01234567"
    static let upstreamCommit = "fedcba9876543210fedcba9876543210fedcba98"
    static let notice = "VoiceInk did not build the Android keyboard APK for this update because this Mac is missing a JDK 17 or later. VoiceInk never installs these itself."

    static func manifest(notice: String?, preparedAt: Date) throws -> Data {
        var manifest: [String: Any] = [
            "forkCommit": forkCommit,
            "forkBaseCommit": forkCommit,
            "upstreamCommit": upstreamCommit,
            "bundlePath": "/tmp/VoiceInk.app",
            "preparedAt": preparedAt,
            "candidateRef": "refs/voiceink-updater/candidates/\(forkCommit)-1-1",
        ]
        if let notice {
            manifest["androidAppNotice"] = notice
        }
        return try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
    }

    @Test
    func manifestDecodesTheAndroidNoticeAndOlderManifestsDecodeWithout() throws {
        let preparedAt = Date(timeIntervalSince1970: 1_787_400_000)
        let withNotice = try PropertyListDecoder().decode(
            StagedForkCandidate.self,
            from: Self.manifest(notice: Self.notice, preparedAt: preparedAt)
        )
        let withoutNotice = try PropertyListDecoder().decode(
            StagedForkCandidate.self,
            from: Self.manifest(notice: nil, preparedAt: preparedAt)
        )

        #expect(withNotice.androidAppNotice == Self.notice)
        #expect(withoutNotice.androidAppNotice == nil)
        let roundTripped = try PropertyListDecoder().decode(
            StagedForkCandidate.self,
            from: PropertyListEncoder().encode(withNotice)
        )
        #expect(roundTripped == withNotice)
    }

    @Test @MainActor
    func preparedCandidateWithANoticeIsStagedAndTheNoticeIsLogged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("staged-candidate.plist")
        try Self.manifest(notice: Self.notice, preparedAt: Date()).write(to: manifestURL)
        let logger = AndroidNoticeLogRecorder()
        let transaction = ForkUpdateTransaction(
            scriptURL: directory.appendingPathComponent("prepare-local-update.sh"),
            manifestURL: manifestURL,
            commandRunner: AndroidNoticeCommandRunnerStub(),
            logger: logger,
            attemptContextStore: ForkUpdateAttemptContextStore(directoryURL: directory)
        )

        let result = try await transaction.prepare(mode: .manual)

        guard case .staged(let candidate) = result else {
            Issue.record("Expected a staged candidate, got \(result)")
            return
        }
        #expect(candidate.forkCommit == Self.forkCommit)
        #expect(candidate.androidAppNotice == Self.notice)
        let staging = await logger.records.filter { $0.stage == .staging && $0.outcome == .succeeded }
        #expect(staging.map(\.message) == [Self.notice])
    }

    @Test
    func updateReadyTextIncludesTheAndroidNotice() {
        let preparedAt = Date(timeIntervalSince1970: 1_787_400_000)
        let candidate = StagedForkCandidate(
            forkCommit: Self.forkCommit,
            upstreamCommit: Self.upstreamCommit,
            bundleURL: URL(fileURLWithPath: "/tmp/VoiceInk.app"),
            preparedAt: preparedAt,
            changeSummary: StagedForkChangeSummary(upstreamCommitCount: 1, upstreamCommitSubjects: ["feat: one"]),
            androidAppNotice: Self.notice
        )

        let presentation = StagedUpdatePresentation(candidate: candidate, now: preparedAt.addingTimeInterval(5))

        #expect(
            presentation.message
                == """
                VoiceInk prepared fork commit 0123456789ab just now.

                1 upstream commit since the installed version:
                • feat: one

                \(Self.notice)
                """
        )
        let withoutNotice = StagedUpdatePresentation(
            candidate: StagedForkCandidate(
                forkCommit: Self.forkCommit,
                upstreamCommit: Self.upstreamCommit,
                bundleURL: URL(fileURLWithPath: "/tmp/VoiceInk.app"),
                preparedAt: preparedAt
            ),
            now: preparedAt.addingTimeInterval(5)
        )
        #expect(withoutNotice.message == "VoiceInk prepared fork commit 0123456789ab just now.")
    }

    @Test @MainActor
    func theAndroidNoticeIsAnnouncedOnceAsAWarningBesideTheReadyUpdate() {
        let suiteName = "ForkUpdateAndroidAppNoticeTests.notifications"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = AndroidNoticeUpdaterAdapterStub()
        let notifications = AndroidNoticeNotificationRecorder()
        let updater: any UpdaterModule = UpdaterViewModel(
            defaults: defaults,
            adapter: adapter,
            notificationDeliverer: notifications,
            logOpener: AndroidNoticeLogOpenerStub()
        )
        let preparedAt = Date(timeIntervalSince1970: 1_787_400_000)
        let candidate = StagedForkCandidate(
            forkCommit: Self.forkCommit,
            upstreamCommit: Self.upstreamCommit,
            bundleURL: URL(fileURLWithPath: "/tmp/VoiceInk.app"),
            preparedAt: preparedAt,
            androidAppNotice: Self.notice
        )
        // The next preparation of the same commit no longer carries the notice.
        let reprepared = StagedForkCandidate(
            forkCommit: Self.forkCommit,
            upstreamCommit: Self.upstreamCommit,
            bundleURL: URL(fileURLWithPath: "/tmp/VoiceInk.app"),
            preparedAt: preparedAt.addingTimeInterval(3_600)
        )

        adapter.send(.stagedCandidate(candidate))
        adapter.send(.stagedCandidate(candidate))
        adapter.send(.stagedCandidate(reprepared))

        #expect(notifications.notifications.map(\.kind) == [.candidateReady, .androidAppNotice])
        #expect(notifications.notifications.last?.title == Self.notice)
        #expect(updater.state.stagedUpdate == reprepared)
        #expect(updater.state.failure == nil)
        #expect(updater.state.preparationError == nil)
    }
}

private struct AndroidNoticeCommandRunnerStub: ForkUpdateCommandRunning {
    func run(
        scriptURL: URL,
        manifestURL: URL,
        installedForkCommit: String?,
        mode: ForkUpdatePreparationMode
    ) async throws -> ForkUpdateCommandResult {
        .candidatePrepared(
            candidateIdentifier: "\(ForkUpdateAndroidAppNoticeTests.forkCommit):\(ForkUpdateAndroidAppNoticeTests.upstreamCommit)"
        )
    }
}

private actor AndroidNoticeLogRecorder: ForkUpdateLogging {
    private(set) var records: [ForkUpdateLogRecord] = []

    func record(_ record: ForkUpdateLogRecord) {
        records.append(record)
    }
}

@MainActor
private final class AndroidNoticeUpdaterAdapterStub: UpdaterAdapter {
    var state = UpdaterAdapterState(
        canCheckForUpdates: true,
        sessionInProgress: false,
        lastUpdateCheckDate: nil,
        updateCheckInterval: 24 * 60 * 60
    )
    var onEvent: ((UpdaterAdapterEvent) -> Void)?
    var canRestorePreviousVersion = false

    func start() {}
    func checkForUpdateInformation() {}
    func checkForUpdates() {}
    func requestRestart(for candidate: StagedForkCandidate) {}
    func restorePreviousVersion() {}
    func send(_ event: UpdaterAdapterEvent) { onEvent?(event) }
}

@MainActor
private final class AndroidNoticeNotificationRecorder: ForkUpdateNotificationDelivering {
    private(set) var notifications: [ForkUpdateUserNotification] = []

    func deliver(_ notification: ForkUpdateUserNotification, action: @escaping () -> Void) {
        notifications.append(notification)
    }
}

@MainActor
private final class AndroidNoticeLogOpenerStub: ForkUpdateLogOpening {
    func openLogs() {}
}
