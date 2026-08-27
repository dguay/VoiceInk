import Foundation
import SwiftUI

struct SourceProvenance: Equatable, Sendable {
    static let forkCommitInfoKey = "VoiceInkForkCommit"
    static let upstreamCommitInfoKey = "VoiceInkUpstreamCommit"

    let forkCommit: String
    let upstreamCommit: String

    static func from(bundle: Bundle) -> SourceProvenance? {
        guard
            let forkCommit = bundle.object(forInfoDictionaryKey: forkCommitInfoKey) as? String,
            let upstreamCommit = bundle.object(forInfoDictionaryKey: upstreamCommitInfoKey) as? String,
            isCommitSHA(forkCommit),
            isCommitSHA(upstreamCommit)
        else {
            return nil
        }

        return SourceProvenance(forkCommit: forkCommit, upstreamCommit: upstreamCommit)
    }

    private static func isCommitSHA(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (65 ... 70).contains(byte) || (97 ... 102).contains(byte)
        }
    }
}

struct UpdaterState: Equatable {
    struct AvailableUpdate: Equatable {
        let versionIdentifier: String
        let displayVersion: String
    }

    var canCheckForUpdates: Bool
    var checksForUpdatesWhenDashboardAppears: Bool
    var availableUpdate: AvailableUpdate?
    var sourceProvenance: SourceProvenance?
    var canRestorePreviousVersion: Bool
    var isPresentingRestorePreviousVersion: Bool
    var stagedUpdate: StagedForkCandidate?
    var isPreparingUpdate: Bool
    var isPresentingStagedUpdate: Bool
    var preparationError: String?
    var failure: ForkUpdateFailure?
    var recoveryWarning: String?
}

@MainActor
protocol UpdaterModule: AnyObject {
    var state: UpdaterState { get }

    func setChecksForUpdatesWhenDashboardAppears(_ value: Bool)
    func checkForUpdatesIfDue()
    func checkForUpdates()
    func showStagedUpdate()
    func deferStagedUpdate()
    func restartAndUpdate()
    func showRestorePreviousVersion()
    func cancelRestorePreviousVersion()
    func restorePreviousVersion()
    func openUpdateLogs()
    func fixFailedUpdate()
}

struct UpdaterAdapterState: Equatable {
    let canCheckForUpdates: Bool
    let sessionInProgress: Bool
    let lastUpdateCheckDate: Date?
    let updateCheckInterval: TimeInterval

    static let unavailable = UpdaterAdapterState(
        canCheckForUpdates: false,
        sessionInProgress: false,
        lastUpdateCheckDate: nil,
        updateCheckInterval: 0
    )
}

enum UpdaterAdapterEvent: Equatable {
    case stateChanged(UpdaterAdapterState)
    case foundUpdate(versionIdentifier: String, displayVersion: String)
    case didNotFindUpdate
    case didFinishUpdateCycle
    case forkUpToDate(SourceProvenance)
    case stagedCandidate(StagedForkCandidate)
    case preparationFailed(ForkUpdateFailure)
    case rollbackReported(LocalUpdateRollbackNotice)
    case rollbackCompleted
}

@MainActor
protocol UpdaterAdapter: AnyObject {
    var state: UpdaterAdapterState { get }
    var onEvent: ((UpdaterAdapterEvent) -> Void)? { get set }
    var canRestorePreviousVersion: Bool { get }

    func start()
    func checkForUpdateInformation()
    func checkForUpdates()
    func requestRestart(for candidate: StagedForkCandidate)
    func restorePreviousVersion()
}

extension UpdaterAdapter {
    var canRestorePreviousVersion: Bool { false }
    func requestRestart(for candidate: StagedForkCandidate) {}
    func restorePreviousVersion() {}
}

@MainActor
enum ProductionUpdaterAdapter {
    static func make(defaults: UserDefaults = .standard) -> any UpdaterAdapter {
        #if LOCAL_BUILD
            if let transaction = ForkUpdateTransaction.production() {
                ForkUpdaterAdapter(transaction: transaction, defaults: defaults)
            } else {
                ForkUpdaterAdapter()
            }
        #else
            SparkleUpdaterAdapter()
        #endif
    }
}

@MainActor
final class UpdaterViewModel: ObservableObject, UpdaterModule {
    private enum DefaultsKey {
        // Keep the existing persisted key strings so current user preferences migrate automatically.
        static let automaticUpdateChecks = "VoiceInkChecksForUpdatesOnLaunch"
        static let interactedUpdateVersions = "VoiceInkInteractedUpdateVersions"
        static let sparkleAutomaticChecks = "SUEnableAutomaticChecks"
        static let notifiedCandidateCommits = "VoiceInkForkUpdaterNotifiedCandidateCommits"
        static let activeFailureNotification = "VoiceInkForkUpdaterActiveFailureNotification"
    }

    private let defaults: UserDefaults
    private let adapter: any UpdaterAdapter
    private let automaticUpdateScheduler: (any AutomaticUpdateScheduling)?
    private let notificationDeliverer: any ForkUpdateNotificationDelivering
    private let logOpener: any ForkUpdateLogOpening
    private let recoveryLauncher: any ForkUpdateRecoveryLaunching
    private var isUserInitiatedUpdateCheck = false

    @Published private(set) var state: UpdaterState

    convenience init() {
        self.init(defaults: .standard)
    }

    convenience init(defaults: UserDefaults) {
        self.init(
            defaults: defaults,
            adapter: ProductionUpdaterAdapter.make(defaults: defaults),
            automaticUpdateScheduler: AutomaticUpdateScheduler()
        )
    }

    init(
        defaults: UserDefaults,
        adapter: any UpdaterAdapter,
        sourceProvenance: SourceProvenance? = SourceProvenance.from(bundle: .main),
        automaticUpdateScheduler: (any AutomaticUpdateScheduling)? = nil,
        notificationDeliverer: any ForkUpdateNotificationDelivering = AppForkUpdateNotificationDeliverer(),
        logOpener: any ForkUpdateLogOpening = WorkspaceForkUpdateLogOpener(),
        recoveryLauncher: (any ForkUpdateRecoveryLaunching)? = nil
    ) {
        self.defaults = defaults
        self.adapter = adapter
        self.automaticUpdateScheduler = automaticUpdateScheduler
        self.notificationDeliverer = notificationDeliverer
        self.logOpener = logOpener
        self.recoveryLauncher = recoveryLauncher ?? CodexForkUpdateRecoveryLauncher()
        state = UpdaterState(
            canCheckForUpdates: adapter.state.canCheckForUpdates,
            checksForUpdatesWhenDashboardAppears: Self.initialAutomaticCheckPreference(in: defaults),
            availableUpdate: nil,
            sourceProvenance: sourceProvenance,
            canRestorePreviousVersion: adapter.canRestorePreviousVersion,
            isPresentingRestorePreviousVersion: false,
            stagedUpdate: nil,
            isPreparingUpdate: adapter.state.sessionInProgress,
            isPresentingStagedUpdate: false,
            preparationError: nil,
            failure: nil,
            recoveryWarning: nil
        )

        adapter.onEvent = { [weak self] event in
            self?.handle(event)
        }
        adapter.start()
        apply(adapter.state)
        automaticUpdateScheduler?.start { [weak self] in
            self?.checkForUpdatesIfDue()
        }
    }

    func setChecksForUpdatesWhenDashboardAppears(_ value: Bool) {
        guard state.checksForUpdatesWhenDashboardAppears != value else { return }

        state.checksForUpdatesWhenDashboardAppears = value
        defaults.set(value, forKey: DefaultsKey.automaticUpdateChecks)

        if value {
            checkForUpdateInformationIfPossible()
        } else {
            state.availableUpdate = nil
        }
    }

    func checkForUpdatesIfDue() {
        guard state.checksForUpdatesWhenDashboardAppears else { return }

        let adapterState = adapter.state
        guard !adapterState.sessionInProgress else { return }

        if let lastCheckDate = adapterState.lastUpdateCheckDate {
            let elapsed = Date().timeIntervalSince(lastCheckDate)
            guard elapsed < 0 || elapsed >= adapterState.updateCheckInterval else { return }
        }

        checkForUpdateInformationIfPossible()
    }

    func checkForUpdates() {
        guard state.canCheckForUpdates else { return }

        state.preparationError = nil
        state.failure = nil
        state.recoveryWarning = nil
        defaults.removeObject(forKey: DefaultsKey.activeFailureNotification)

        // Any explicit check is interaction with the currently advertised update.
        // Persist it before presenting the adapter's update UI so dismissing or closing
        // that UI cannot make the Dashboard button reappear for the same build.
        if let availableUpdate = state.availableUpdate {
            rememberInteraction(with: availableUpdate.versionIdentifier)
            state.availableUpdate = nil
        }

        if !adapter.state.sessionInProgress {
            isUserInitiatedUpdateCheck = true
        }
        adapter.checkForUpdates()
    }

    func showStagedUpdate() {
        guard state.stagedUpdate != nil else { return }
        state.isPresentingStagedUpdate = true
    }

    func deferStagedUpdate() {
        state.isPresentingStagedUpdate = false
    }

    func restartAndUpdate() {
        guard let candidate = state.stagedUpdate else { return }
        state.isPresentingStagedUpdate = false
        adapter.requestRestart(for: candidate)
    }

    func restorePreviousVersion() {
        guard state.canRestorePreviousVersion else { return }
        state.isPresentingRestorePreviousVersion = false
        adapter.restorePreviousVersion()
    }

    func showRestorePreviousVersion() {
        guard state.canRestorePreviousVersion else { return }
        state.isPresentingRestorePreviousVersion = true
    }

    func cancelRestorePreviousVersion() {
        state.isPresentingRestorePreviousVersion = false
    }

    func openUpdateLogs() {
        logOpener.openLogs()
    }

    func fixFailedUpdate() {
        guard let context = state.failure?.attemptContext else {
            state.recoveryWarning = "VoiceInk could not find the saved failed update attempt. Retry the update first."
            return
        }
        do {
            try recoveryLauncher.launchRecovery(for: context)
            state.recoveryWarning = nil
        } catch {
            state.recoveryWarning = error.localizedDescription
        }
    }

    private func handle(_ event: UpdaterAdapterEvent) {
        switch event {
        case .stateChanged(let adapterState):
            apply(adapterState)
        case .foundUpdate(let versionIdentifier, let displayVersion):
            handleFoundUpdate(versionIdentifier: versionIdentifier, displayVersion: displayVersion)
        case .didNotFindUpdate:
            state.availableUpdate = nil
        case .didFinishUpdateCycle:
            isUserInitiatedUpdateCheck = false
        case .forkUpToDate(let provenance):
            state.sourceProvenance = provenance
            state.stagedUpdate = nil
            state.isPresentingStagedUpdate = false
            state.preparationError = nil
            state.failure = nil
            state.recoveryWarning = nil
            defaults.removeObject(forKey: DefaultsKey.activeFailureNotification)
        case .stagedCandidate(let candidate):
            state.stagedUpdate = candidate
            state.isPresentingStagedUpdate = true
            state.preparationError = nil
            state.failure = nil
            state.recoveryWarning = nil
            defaults.removeObject(forKey: DefaultsKey.activeFailureNotification)
            notifyCandidateIfNeeded(candidate)
        case .preparationFailed(let failure):
            state.stagedUpdate = nil
            state.isPresentingStagedUpdate = false
            state.preparationError = failure.message
            state.failure = failure
            state.recoveryWarning = nil
            notifyFailureIfNeeded(failure)
        case .rollbackReported(let notice):
            if notice.initiator == .manual, notice.outcome == .succeeded {
                state.failure = nil
                state.preparationError = nil
                state.recoveryWarning = nil
            }
            let title: String
            switch (notice.initiator, notice.outcome) {
            case (.automatic, .succeeded):
                title = "VoiceInk restored the previous version after the update failed."
            case (.automatic, _):
                title = "VoiceInk could not complete the automatic rollback."
            case (.manual, .succeeded):
                title = "VoiceInk restored the previous version."
            case (.manual, _):
                title = "VoiceInk could not restore the previous version."
            }
            notificationDeliverer.deliver(
                ForkUpdateUserNotification(
                    identifier: "rollback-\(notice.initiator.rawValue)-\(notice.candidateIdentifier)-\(notice.outcome.rawValue)",
                    kind: notice.outcome == .succeeded ? .rollbackSucceeded : .rollbackFailed,
                    title: title,
                    actionLabel: "Open Logs"
                ),
                action: { [weak self] in self?.openUpdateLogs() }
            )
        case .rollbackCompleted:
            state.failure = nil
            state.preparationError = nil
            state.recoveryWarning = nil
            defaults.removeObject(forKey: DefaultsKey.activeFailureNotification)
            notificationDeliverer.deliver(
                ForkUpdateUserNotification(
                    identifier: "rollback-completed",
                    kind: .rollbackSucceeded,
                    title: "VoiceInk restored the previous version.",
                    actionLabel: "Open Logs"
                ),
                action: { [weak self] in self?.openUpdateLogs() }
            )
        }
    }

    private func notifyCandidateIfNeeded(_ candidate: StagedForkCandidate) {
        var commits = defaults.stringArray(forKey: DefaultsKey.notifiedCandidateCommits) ?? []
        guard !commits.contains(candidate.forkCommit) else { return }
        commits.append(candidate.forkCommit)
        defaults.set(Array(commits.suffix(20)), forKey: DefaultsKey.notifiedCandidateCommits)
        notificationDeliverer.deliver(
            ForkUpdateUserNotification(
                identifier: "candidate-\(candidate.forkCommit)",
                kind: .candidateReady,
                title: "A verified VoiceInk update is ready.",
                actionLabel: "View"
            ),
            action: { [weak self] in self?.showStagedUpdate() }
        )
    }

    private func notifyFailureIfNeeded(_ failure: ForkUpdateFailure) {
        let identifier = "\(failure.candidateIdentifier ?? "unknown"):\(failure.stage.rawValue)"
        guard defaults.string(forKey: DefaultsKey.activeFailureNotification) != identifier else {
            return
        }
        defaults.set(identifier, forKey: DefaultsKey.activeFailureNotification)
        let kind: ForkUpdateUserNotification.Kind
        switch failure.stage {
        case .permission:
            kind = .permissionRegression
        case .rollback:
            kind = .rollbackFailed
        default:
            kind = .persistentFailure
        }
        notificationDeliverer.deliver(
            ForkUpdateUserNotification(
                identifier: identifier,
                kind: kind,
                title: failure.message,
                actionLabel: failure.attemptContext == nil ? "Open Logs" : "Fix VoiceInk Update"
            ),
            action: { [weak self] in
                if failure.attemptContext == nil {
                    self?.openUpdateLogs()
                } else {
                    self?.fixFailedUpdate()
                }
            }
        )
    }

    private func apply(_ adapterState: UpdaterAdapterState) {
        state.canCheckForUpdates = adapterState.canCheckForUpdates
        state.isPreparingUpdate = adapterState.sessionInProgress
    }

    private func handleFoundUpdate(versionIdentifier: String, displayVersion: String) {
        let update = UpdaterState.AvailableUpdate(
            versionIdentifier: versionIdentifier,
            displayVersion: displayVersion
        )

        if isUserInitiatedUpdateCheck {
            rememberInteraction(with: update.versionIdentifier)
            state.availableUpdate = nil
        } else if state.checksForUpdatesWhenDashboardAppears && !hasInteracted(with: update.versionIdentifier) {
            state.availableUpdate = update
        } else {
            state.availableUpdate = nil
        }
    }

    private func checkForUpdateInformationIfPossible() {
        guard !adapter.state.sessionInProgress else { return }
        adapter.checkForUpdateInformation()
    }

    private func hasInteracted(with versionIdentifier: String) -> Bool {
        defaults.stringArray(forKey: DefaultsKey.interactedUpdateVersions)?
            .contains(versionIdentifier) == true
    }

    private func rememberInteraction(with versionIdentifier: String) {
        var versions = defaults.stringArray(forKey: DefaultsKey.interactedUpdateVersions) ?? []
        guard !versions.contains(versionIdentifier) else { return }
        versions.append(versionIdentifier)
        defaults.set(versions, forKey: DefaultsKey.interactedUpdateVersions)
    }

    private static func initialAutomaticCheckPreference(in defaults: UserDefaults) -> Bool {
        if let preference = defaults.object(forKey: DefaultsKey.automaticUpdateChecks) as? Bool {
            return preference
        }

        // Preserve an explicit choice made through VoiceInk's previous Sparkle-backed
        // setting. With no saved choice, keep VoiceInk's existing opt-in default.
        let preference = (defaults.object(forKey: DefaultsKey.sparkleAutomaticChecks) as? Bool) ?? true

        defaults.set(preference, forKey: DefaultsKey.automaticUpdateChecks)
        return preference
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        Button("Check for Updates…", action: updaterViewModel.checkForUpdates)
            .disabled(!updaterViewModel.state.canCheckForUpdates)
    }
}
