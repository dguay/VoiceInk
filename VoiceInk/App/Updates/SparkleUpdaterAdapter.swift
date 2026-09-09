#if !LOCAL_BUILD
    import Combine
    import Sparkle

    @MainActor
    final class SparkleUpdaterAdapter: NSObject, UpdaterAdapter, SPUUpdaterDelegate {
        var onEvent: ((UpdaterAdapterEvent) -> Void)?

        var state: UpdaterAdapterState {
            let updater = updaterController.updater
            return UpdaterAdapterState(
                canCheckForUpdates: updater.canCheckForUpdates,
                sessionInProgress: updater.sessionInProgress,
                lastUpdateCheckDate: updater.lastUpdateCheckDate,
                updateCheckInterval: updater.updateCheckInterval
            )
        }

        private lazy var updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        private var cancellables: Set<AnyCancellable> = []

        func start() {
            let updater = updaterController.updater

            // VoiceInk owns automatic discovery through Sparkle's non-presenting probe.
            // Keeping Sparkle's scheduler disabled prevents it from showing an update
            // window independently of the Dashboard button.
            updater.automaticallyChecksForUpdates = false
            updaterController.startUpdater()

            updater.publisher(for: \.canCheckForUpdates)
                .sink { [weak self] _ in
                    self?.publishState()
                }
                .store(in: &cancellables)

            publishState()
        }

        func checkForUpdateInformation() {
            updaterController.updater.checkForUpdateInformation()
        }

        func checkForUpdates() {
            updaterController.checkForUpdates(nil)
        }

        func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
            onEvent?(
                .foundUpdate(
                    versionIdentifier: item.versionString,
                    displayVersion: item.displayVersionString
                )
            )
        }

        func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
            onEvent?(.didNotFindUpdate)
        }

        func updater(
            _ updater: SPUUpdater,
            didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
            error: Error?
        ) {
            onEvent?(.didFinishUpdateCycle)
            publishState()
        }

        private func publishState() {
            onEvent?(.stateChanged(state))
        }
    }
#endif
