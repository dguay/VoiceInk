import Foundation

struct StagedForkCandidate: Codable, Equatable {
    let forkCommit: String
    let upstreamCommit: String
    let bundleURL: URL
    let preparedAt: Date

    private enum CodingKeys: String, CodingKey {
        case forkCommit
        case upstreamCommit
        case bundlePath
        case preparedAt
    }

    init(forkCommit: String, upstreamCommit: String, bundleURL: URL, preparedAt: Date) {
        self.forkCommit = forkCommit
        self.upstreamCommit = upstreamCommit
        self.bundleURL = bundleURL
        self.preparedAt = preparedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        forkCommit = try container.decode(String.self, forKey: .forkCommit)
        upstreamCommit = try container.decode(String.self, forKey: .upstreamCommit)
        bundleURL = URL(
            fileURLWithPath: try container.decode(String.self, forKey: .bundlePath)
        )
        preparedAt = try container.decode(Date.self, forKey: .preparedAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(forkCommit, forKey: .forkCommit)
        try container.encode(upstreamCommit, forKey: .upstreamCommit)
        try container.encode(bundleURL.path, forKey: .bundlePath)
        try container.encode(preparedAt, forKey: .preparedAt)
    }
}

@MainActor
protocol ForkUpdateTransacting: AnyObject {
    var canRestorePreviousVersion: Bool { get }
    func loadStagedCandidate() throws -> StagedForkCandidate?
    func prepare() async throws -> StagedForkCandidate
    func requestRestart(for candidate: StagedForkCandidate) async throws -> StagedForkCandidate?
    func restorePreviousVersion() async throws
}

protocol ForkUpdateCommandRunning {
    func run(scriptURL: URL, manifestURL: URL) async throws
}

enum ForkUpdateInstallationOutcome: Equatable {
    case completed
    case candidateStale
}

struct ForkUpdateInstallationRequest: Equatable {
    let scriptURL: URL
    let candidate: StagedForkCandidate
    let manifestURL: URL
    let targetBundleURL: URL
    let backupBundleURL: URL
    let parentProcessIdentifier: Int32
}

protocol ForkUpdateInstalling {
    func install(_ request: ForkUpdateInstallationRequest) async throws -> ForkUpdateInstallationOutcome
}

struct ForkUpdateRestorationRequest: Equatable {
    let scriptURL: URL
    let targetBundleURL: URL
    let backupBundleURL: URL
    let parentProcessIdentifier: Int32
}

protocol ForkUpdateRestoring {
    func restore(_ request: ForkUpdateRestorationRequest) async throws
}

struct LocalUpdateRecoveryState: Codable, Equatable {
    let previousForkCommit: String
    let candidateForkCommit: String
}

struct ForkUpdateError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct ProcessForkUpdateCommandRunner: ForkUpdateCommandRunning {
    func run(scriptURL: URL, manifestURL: URL) async throws {
        try await Task.detached {
            let process = Process()
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("voiceink-update-\(UUID().uuidString).log")
            _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: outputURL)
            defer {
                try? output.close()
                try? FileManager.default.removeItem(at: outputURL)
            }
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path]
            process.standardOutput = output
            process.standardError = output
            var environment = ProcessInfo.processInfo.environment
            environment["VOICEINK_UPDATE_MANIFEST_PATH"] = manifestURL.path
            environment["VOICEINK_UPDATE_RETRY_SUPPRESSED_CANDIDATE"] = "1"
            process.environment = environment

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                try output.synchronize()
                let reader = try FileHandle(forReadingFrom: outputURL)
                defer { try? reader.close() }
                let outputSize = try reader.seekToEnd()
                try reader.seek(toOffset: outputSize > 16_384 ? outputSize - 16_384 : 0)
                let outputData = try reader.readToEnd() ?? Data()
                let message = String(data: outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ForkUpdateError(
                    message: message.flatMap { $0.isEmpty ? nil : $0 }
                        ?? "VoiceInk could not prepare the local update."
                )
            }
        }.value
    }
}

struct ProcessForkUpdateInstallationRunner: ForkUpdateInstalling {
    func install(_ request: ForkUpdateInstallationRequest) async throws -> ForkUpdateInstallationOutcome {
        try await Task.detached {
            let process = Process()
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("voiceink-install-\(UUID().uuidString).log")
            _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: outputURL)
            defer {
                try? output.close()
                try? FileManager.default.removeItem(at: outputURL)
            }

            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [
                request.scriptURL.path,
                request.candidate.forkCommit,
                request.manifestURL.path,
                request.targetBundleURL.path,
                request.backupBundleURL.path,
                String(request.parentProcessIdentifier),
            ]
            process.standardOutput = output
            process.standardError = output
            process.environment = ProcessInfo.processInfo.environment

            try process.run()
            process.waitUntilExit()

            switch process.terminationStatus {
            case 0:
                return .completed
            case 75:
                return .candidateStale
            default:
                try output.synchronize()
                let reader = try FileHandle(forReadingFrom: outputURL)
                defer { try? reader.close() }
                let outputSize = try reader.seekToEnd()
                try reader.seek(toOffset: outputSize > 16_384 ? outputSize - 16_384 : 0)
                let outputData = try reader.readToEnd() ?? Data()
                let message = String(data: outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ForkUpdateError(
                    message: message.flatMap { $0.isEmpty ? nil : $0 }
                        ?? "VoiceInk could not install the local update."
                )
            }
        }.value
    }
}

struct ProcessForkUpdateRestorationRunner: ForkUpdateRestoring {
    func restore(_ request: ForkUpdateRestorationRequest) async throws {
        try await Task.detached {
            let process = Process()
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("voiceink-restore-\(UUID().uuidString).log")
            _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: outputURL)
            defer {
                try? output.close()
                try? FileManager.default.removeItem(at: outputURL)
            }

            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [
                request.scriptURL.path,
                request.targetBundleURL.path,
                request.backupBundleURL.path,
                String(request.parentProcessIdentifier),
            ]
            process.standardOutput = output
            process.standardError = output
            process.environment = ProcessInfo.processInfo.environment

            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                try output.synchronize()
                let reader = try FileHandle(forReadingFrom: outputURL)
                defer { try? reader.close() }
                let outputSize = try reader.seekToEnd()
                try reader.seek(toOffset: outputSize > 16_384 ? outputSize - 16_384 : 0)
                let outputData = try reader.readToEnd() ?? Data()
                let message = String(data: outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ForkUpdateError(
                    message: message.flatMap { $0.isEmpty ? nil : $0 }
                        ?? "VoiceInk could not restore the previous version."
                )
            }
        }.value
    }
}

@MainActor
final class ForkUpdateTransaction: ForkUpdateTransacting {
    private let scriptURL: URL
    private let manifestURL: URL
    private let commandRunner: any ForkUpdateCommandRunning
    private let installationScriptURL: URL?
    private let restorationScriptURL: URL?
    private let targetBundleURL: URL?
    private let backupBundleURL: URL?
    private let parentProcessIdentifier: Int32
    private let credentialSnapshotter: any ForkUpdateCredentialSnapshotting
    private let installationRunner: any ForkUpdateInstalling
    private let restorationRunner: any ForkUpdateRestoring

    init(
        scriptURL: URL,
        manifestURL: URL,
        commandRunner: any ForkUpdateCommandRunning = ProcessForkUpdateCommandRunner(),
        installationScriptURL: URL? = nil,
        restorationScriptURL: URL? = nil,
        targetBundleURL: URL? = nil,
        backupBundleURL: URL? = nil,
        parentProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        credentialSnapshotter: any ForkUpdateCredentialSnapshotting = LocalUpdateCredentialSnapshotStore(),
        installationRunner: any ForkUpdateInstalling = ProcessForkUpdateInstallationRunner(),
        restorationRunner: any ForkUpdateRestoring = ProcessForkUpdateRestorationRunner()
    ) {
        self.scriptURL = scriptURL
        self.manifestURL = manifestURL
        self.commandRunner = commandRunner
        self.installationScriptURL = installationScriptURL
        self.restorationScriptURL = restorationScriptURL
        self.targetBundleURL = targetBundleURL
        self.backupBundleURL = backupBundleURL
        self.parentProcessIdentifier = parentProcessIdentifier
        self.credentialSnapshotter = credentialSnapshotter
        self.installationRunner = installationRunner
        self.restorationRunner = restorationRunner
    }

    static func production(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> ForkUpdateTransaction? {
        guard let scriptURL = bundle.url(
            forResource: "prepare-local-update",
            withExtension: "sh"
        ), let installationScriptURL = bundle.url(
            forResource: "install-local-update",
            withExtension: "sh"
        ), let restorationScriptURL = bundle.url(
            forResource: "restore-local-update",
            withExtension: "sh"
        ) else {
            return nil
        }
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let manifestURL = applicationSupport
            .appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
            .appendingPathComponent("Updater", isDirectory: true)
            .appendingPathComponent("staged-candidate.plist")
        return ForkUpdateTransaction(
            scriptURL: scriptURL,
            manifestURL: manifestURL,
            installationScriptURL: installationScriptURL,
            restorationScriptURL: restorationScriptURL,
            targetBundleURL: bundle.bundleURL,
            backupBundleURL: applicationSupport
                .appendingPathComponent(
                    "com.prakashjoshipax.VoiceInk.UpdaterRecovery",
                    isDirectory: true
                )
                .appendingPathComponent("VoiceInk.app", isDirectory: true)
        )
    }

    var canRestorePreviousVersion: Bool {
        guard
            let targetBundleURL,
            let backupBundleURL,
            FileManager.default.fileExists(atPath: backupBundleURL.path),
            let recoveryState = try? loadRecoveryState(backupBundleURL: backupBundleURL),
            let currentForkCommit = try? installedForkCommit(at: targetBundleURL)
        else {
            return false
        }
        return currentForkCommit == recoveryState.candidateForkCommit
    }

    func loadStagedCandidate() throws -> StagedForkCandidate? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let data = try Data(contentsOf: manifestURL)
        return try PropertyListDecoder().decode(StagedForkCandidate.self, from: data)
    }

    func prepare() async throws -> StagedForkCandidate {
        try await commandRunner.run(scriptURL: scriptURL, manifestURL: manifestURL)
        guard let candidate = try loadStagedCandidate() else {
            throw ForkUpdateError(
                message: "The local updater finished without staging a candidate."
            )
        }
        return candidate
    }

    func requestRestart(for candidate: StagedForkCandidate) async throws -> StagedForkCandidate? {
        guard let stagedCandidate = try loadStagedCandidate() else {
            return try await prepare()
        }
        guard stagedCandidate == candidate else {
            return stagedCandidate
        }
        guard let installationScriptURL, let targetBundleURL, let backupBundleURL else {
            throw ForkUpdateError(
                message: "VoiceInk could not find its local installation helper."
            )
        }

        try credentialSnapshotter.createSnapshot()

        let outcome = try await installationRunner.install(
            ForkUpdateInstallationRequest(
                scriptURL: installationScriptURL,
                candidate: candidate,
                manifestURL: manifestURL,
                targetBundleURL: targetBundleURL,
                backupBundleURL: backupBundleURL,
                parentProcessIdentifier: parentProcessIdentifier
            )
        )
        switch outcome {
        case .completed:
            return nil
        case .candidateStale:
            return try await prepare()
        }
    }

    func restorePreviousVersion() async throws {
        guard
            canRestorePreviousVersion,
            let restorationScriptURL,
            let targetBundleURL,
            let backupBundleURL
        else {
            throw ForkUpdateError(message: "VoiceInk does not have a previous version to restore.")
        }
        try await restorationRunner.restore(
            ForkUpdateRestorationRequest(
                scriptURL: restorationScriptURL,
                targetBundleURL: targetBundleURL,
                backupBundleURL: backupBundleURL,
                parentProcessIdentifier: parentProcessIdentifier
            )
        )
    }

    private func loadRecoveryState(backupBundleURL: URL) throws -> LocalUpdateRecoveryState {
        let stateURL = backupBundleURL.deletingLastPathComponent().appendingPathComponent("recovery.plist")
        return try PropertyListDecoder().decode(
            LocalUpdateRecoveryState.self,
            from: Data(contentsOf: stateURL)
        )
    }

    private func installedForkCommit(at bundleURL: URL) throws -> String {
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL),
            options: [],
            format: nil
        )
        guard
            let dictionary = info as? [String: Any],
            let forkCommit = dictionary[SourceProvenance.forkCommitInfoKey] as? String
        else {
            throw ForkUpdateError(message: "VoiceInk could not read the installed source revision.")
        }
        return forkCommit
    }
}

@MainActor
final class ForkUpdaterAdapter: UpdaterAdapter {
    private(set) var state: UpdaterAdapterState
    var onEvent: ((UpdaterAdapterEvent) -> Void)?

    private let transaction: (any ForkUpdateTransacting)?
    private var stagedCandidate: StagedForkCandidate?

    init() {
        transaction = nil
        state = .unavailable
    }

    init(transaction: any ForkUpdateTransacting) {
        self.transaction = transaction
        state = UpdaterAdapterState(
            canCheckForUpdates: true,
            sessionInProgress: false,
            lastUpdateCheckDate: nil,
            updateCheckInterval: 0
        )
    }

    var canRestorePreviousVersion: Bool {
        transaction?.canRestorePreviousVersion == true
    }

    func start() {
        onEvent?(.stateChanged(state))
        guard let candidate = try? transaction?.loadStagedCandidate() else { return }
        stagedCandidate = candidate
        onEvent?(.stagedCandidate(candidate))
    }

    func checkForUpdateInformation() {}

    func checkForUpdates() {
        guard let transaction, !state.sessionInProgress else { return }

        state = UpdaterAdapterState(
            canCheckForUpdates: state.canCheckForUpdates,
            sessionInProgress: true,
            lastUpdateCheckDate: state.lastUpdateCheckDate,
            updateCheckInterval: state.updateCheckInterval
        )
        onEvent?(.stateChanged(state))

        Task { [weak self] in
            do {
                let candidate = try await transaction.prepare()
                self?.stagedCandidate = candidate
                self?.onEvent?(.stagedCandidate(candidate))
            } catch {
                self?.onEvent?(.preparationFailed(error.localizedDescription))
            }
            self?.finishUpdateCycle()
        }
    }

    func requestRestart(for candidate: StagedForkCandidate) {
        guard let transaction, candidate == stagedCandidate, !state.sessionInProgress else { return }

        state = UpdaterAdapterState(
            canCheckForUpdates: state.canCheckForUpdates,
            sessionInProgress: true,
            lastUpdateCheckDate: state.lastUpdateCheckDate,
            updateCheckInterval: state.updateCheckInterval
        )
        onEvent?(.stateChanged(state))

        Task { [weak self] in
            do {
                if let replacement = try await transaction.requestRestart(for: candidate) {
                    self?.stagedCandidate = replacement
                    self?.onEvent?(.stagedCandidate(replacement))
                }
            } catch {
                self?.onEvent?(.preparationFailed(error.localizedDescription))
            }
            self?.finishUpdateCycle()
        }
    }

    func restorePreviousVersion() {
        guard let transaction, transaction.canRestorePreviousVersion, !state.sessionInProgress else { return }

        state = UpdaterAdapterState(
            canCheckForUpdates: state.canCheckForUpdates,
            sessionInProgress: true,
            lastUpdateCheckDate: state.lastUpdateCheckDate,
            updateCheckInterval: state.updateCheckInterval
        )
        onEvent?(.stateChanged(state))

        Task { [weak self] in
            do {
                try await transaction.restorePreviousVersion()
            } catch {
                self?.onEvent?(.preparationFailed(error.localizedDescription))
            }
            self?.finishUpdateCycle()
        }
    }

    private func finishUpdateCycle() {
        state = UpdaterAdapterState(
            canCheckForUpdates: state.canCheckForUpdates,
            sessionInProgress: false,
            lastUpdateCheckDate: Date(),
            updateCheckInterval: state.updateCheckInterval
        )
        onEvent?(.stateChanged(state))
        onEvent?(.didFinishUpdateCycle)
    }
}
