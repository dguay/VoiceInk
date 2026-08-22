import Foundation
import SwiftUI

struct SourceProvenance: Equatable {
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
}

@MainActor
protocol UpdaterModule: AnyObject {
    var state: UpdaterState { get }

    func setChecksForUpdatesWhenDashboardAppears(_ value: Bool)
    func checkForUpdatesIfDue()
    func checkForUpdates()
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
}

@MainActor
protocol UpdaterAdapter: AnyObject {
    var state: UpdaterAdapterState { get }
    var onEvent: ((UpdaterAdapterEvent) -> Void)? { get set }

    func start()
    func checkForUpdateInformation()
    func checkForUpdates()
}

@MainActor
final class ForkUpdaterAdapter: UpdaterAdapter {
    let state = UpdaterAdapterState.unavailable
    var onEvent: ((UpdaterAdapterEvent) -> Void)?

    func start() {
        onEvent?(.stateChanged(state))
    }

    func checkForUpdateInformation() {}

    func checkForUpdates() {}
}

@MainActor
enum ProductionUpdaterAdapter {
    static func make() -> any UpdaterAdapter {
        #if LOCAL_BUILD
            ForkUpdaterAdapter()
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
    }

    private let defaults: UserDefaults
    private let adapter: any UpdaterAdapter
    private var isUserInitiatedUpdateCheck = false

    @Published private(set) var state: UpdaterState

    convenience init() {
        self.init(defaults: .standard)
    }

    convenience init(defaults: UserDefaults) {
        self.init(defaults: defaults, adapter: ProductionUpdaterAdapter.make())
    }

    init(
        defaults: UserDefaults,
        adapter: any UpdaterAdapter,
        sourceProvenance: SourceProvenance? = SourceProvenance.from(bundle: .main)
    ) {
        self.defaults = defaults
        self.adapter = adapter
        state = UpdaterState(
            canCheckForUpdates: adapter.state.canCheckForUpdates,
            checksForUpdatesWhenDashboardAppears: Self.initialAutomaticCheckPreference(in: defaults),
            availableUpdate: nil,
            sourceProvenance: sourceProvenance
        )

        adapter.onEvent = { [weak self] event in
            self?.handle(event)
        }
        adapter.start()
        apply(adapter.state)
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
        }
    }

    private func apply(_ adapterState: UpdaterAdapterState) {
        state.canCheckForUpdates = adapterState.canCheckForUpdates
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
