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
protocol ForkUpdatePreparing: AnyObject {
    func loadStagedCandidate() throws -> StagedForkCandidate?
    func prepare() async throws -> StagedForkCandidate
    func requestRestart(for candidate: StagedForkCandidate)
}

protocol ForkUpdateCommandRunning {
    func run(scriptURL: URL, manifestURL: URL) async throws
}

struct ForkUpdatePreparationError: LocalizedError {
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
                throw ForkUpdatePreparationError(
                    message: message.flatMap { $0.isEmpty ? nil : $0 }
                        ?? "VoiceInk could not prepare the local update."
                )
            }
        }.value
    }
}

@MainActor
final class ForkUpdatePreparationService: ForkUpdatePreparing {
    private let scriptURL: URL
    private let manifestURL: URL
    private let commandRunner: any ForkUpdateCommandRunning

    init(
        scriptURL: URL,
        manifestURL: URL,
        commandRunner: any ForkUpdateCommandRunning = ProcessForkUpdateCommandRunner()
    ) {
        self.scriptURL = scriptURL
        self.manifestURL = manifestURL
        self.commandRunner = commandRunner
    }

    static func production(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> ForkUpdatePreparationService? {
        guard let scriptURL = bundle.url(
            forResource: "prepare-local-update",
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
        return ForkUpdatePreparationService(
            scriptURL: scriptURL,
            manifestURL: manifestURL
        )
    }

    func loadStagedCandidate() throws -> StagedForkCandidate? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let data = try Data(contentsOf: manifestURL)
        return try PropertyListDecoder().decode(StagedForkCandidate.self, from: data)
    }

    func prepare() async throws -> StagedForkCandidate {
        try await commandRunner.run(scriptURL: scriptURL, manifestURL: manifestURL)
        guard let candidate = try loadStagedCandidate() else {
            throw ForkUpdatePreparationError(
                message: "The local updater finished without staging a candidate."
            )
        }
        return candidate
    }

    func requestRestart(for candidate: StagedForkCandidate) {
        // Issue #5 turns this explicit request into an installation transaction.
    }
}

@MainActor
final class ForkUpdaterAdapter: UpdaterAdapter {
    private(set) var state: UpdaterAdapterState
    var onEvent: ((UpdaterAdapterEvent) -> Void)?

    private let preparer: (any ForkUpdatePreparing)?
    private var stagedCandidate: StagedForkCandidate?

    init() {
        preparer = nil
        state = .unavailable
    }

    init(preparer: any ForkUpdatePreparing) {
        self.preparer = preparer
        state = UpdaterAdapterState(
            canCheckForUpdates: true,
            sessionInProgress: false,
            lastUpdateCheckDate: nil,
            updateCheckInterval: 0
        )
    }

    func start() {
        onEvent?(.stateChanged(state))
        guard let candidate = try? preparer?.loadStagedCandidate() else { return }
        stagedCandidate = candidate
        onEvent?(.stagedCandidate(candidate))
    }

    func checkForUpdateInformation() {}

    func checkForUpdates() {
        guard let preparer, !state.sessionInProgress else { return }

        state = UpdaterAdapterState(
            canCheckForUpdates: state.canCheckForUpdates,
            sessionInProgress: true,
            lastUpdateCheckDate: state.lastUpdateCheckDate,
            updateCheckInterval: state.updateCheckInterval
        )
        onEvent?(.stateChanged(state))

        Task { [weak self] in
            do {
                let candidate = try await preparer.prepare()
                self?.stagedCandidate = candidate
                self?.onEvent?(.stagedCandidate(candidate))
            } catch {
                self?.onEvent?(.preparationFailed(error.localizedDescription))
            }
            self?.finishPreparation()
        }
    }

    func requestRestart(for candidate: StagedForkCandidate) {
        guard candidate == stagedCandidate else { return }
        preparer?.requestRestart(for: candidate)
    }

    private func finishPreparation() {
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
