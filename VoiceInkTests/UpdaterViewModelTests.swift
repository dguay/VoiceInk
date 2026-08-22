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
            #expect(ProductionUpdaterAdapter.make() is ForkUpdaterAdapter)
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
}

@MainActor
private final class OfficialUpdaterAdapterStub: UpdaterAdapter {
    var state: UpdaterAdapterState
    var onEvent: ((UpdaterAdapterEvent) -> Void)?
    private(set) var startCount = 0
    private(set) var userInitiatedCheckCount = 0
    private(set) var informationCheckCount = 0

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

    func send(_ event: UpdaterAdapterEvent) {
        onEvent?(event)
    }
}
