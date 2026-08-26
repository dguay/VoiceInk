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

enum ForkUpdatePreparationResult: Equatable {
    case upToDate(SourceProvenance)
    case buildDeferred
    case staged(StagedForkCandidate)
    case failureSuppressed(ForkUpdateFailure)
}

enum ForkUpdatePreparationMode: Equatable, Sendable {
    case automatic(deferBuild: Bool)
    case candidateRevalidation
    case manual

    var isAutomatic: Bool {
        if case .automatic = self { return true }
        return false
    }

    var defersBuild: Bool {
        if case .automatic(deferBuild: true) = self { return true }
        return false
    }

    var retriesSuppressedCandidate: Bool {
        self == .manual
    }
}

protocol ForkUpdatePowerStateProviding {
    var isLowPowerModeEnabled: Bool { get }
}

struct SystemForkUpdatePowerState: ForkUpdatePowerStateProviding {
    var isLowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

@MainActor
protocol ForkUpdateTransacting: AnyObject {
    var canRestorePreviousVersion: Bool { get }
    func loadStagedCandidate() throws -> StagedForkCandidate?
    func loadPersistentFailure() throws -> ForkUpdateFailure?
    func persistFailure(_ failure: ForkUpdateFailure) throws
    func clearPersistentFailure() throws
    func prepare(mode: ForkUpdatePreparationMode) async throws -> ForkUpdatePreparationResult
    func requestRestart(for candidate: StagedForkCandidate) async throws -> StagedForkCandidate?
    func restorePreviousVersion() async throws
}

extension ForkUpdateTransacting {
    func loadPersistentFailure() throws -> ForkUpdateFailure? { nil }
    func persistFailure(_ failure: ForkUpdateFailure) throws {}
    func clearPersistentFailure() throws {}
}

protocol ForkUpdateCommandRunning {
    func run(
        scriptURL: URL,
        manifestURL: URL,
        installedForkCommit: String?,
        mode: ForkUpdatePreparationMode
    ) async throws -> ForkUpdateCommandResult
}

enum ForkUpdateCommandResult: Equatable, Sendable {
    case upToDate(SourceProvenance)
    case buildDeferred
    case candidatePrepared(candidateIdentifier: String?)
    case failureSuppressed(ForkUpdateFailure)
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
    let credentialGeneration: String
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
    let credentialGeneration: String
    let suppressedForkCommit: String?
    let installInProgress: Bool?
    let restoreInProgress: Bool?
}

struct ForkUpdateError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct ProcessForkUpdateCommandRunner: ForkUpdateCommandRunning {
    private struct Report: Decodable {
        let outcome: String
        let forkCommit: String?
        let upstreamCommit: String?
        let stage: ForkUpdateStage?
        let kind: ForkUpdateFailureKind?
        let candidateIdentifier: String?
        let message: String?
    }

    private let retryDelays: [TimeInterval]
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let logger: any ForkUpdateLogging

    init(
        retryDelays: [TimeInterval] = [1, 5],
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(for: .seconds(delay))
        },
        logger: any ForkUpdateLogging = ForkUpdateLogStore.shared
    ) {
        self.retryDelays = retryDelays
        self.sleep = sleep
        self.logger = logger
    }

    func run(
        scriptURL: URL,
        manifestURL: URL,
        installedForkCommit: String?,
        mode: ForkUpdatePreparationMode
    ) async throws -> ForkUpdateCommandResult {
        let priority: TaskPriority = mode.isAutomatic ? .utility : .userInitiated
        let attemptIdentifier = UUID().uuidString.lowercased()
        await logger.record(
            ForkUpdateLogRecord(
                timestamp: Date(),
                attemptIdentifier: attemptIdentifier,
                stage: .preflight,
                outcome: .started,
                candidateIdentifier: nil,
                forkCommit: installedForkCommit,
                upstreamCommit: nil,
                retry: nil,
                message: nil
            )
        )
        return try await Task.detached(priority: priority) {
            for attempt in 0 ... retryDelays.count {
                do {
                    let result = try Self.runOnce(
                        scriptURL: scriptURL,
                        manifestURL: manifestURL,
                        installedForkCommit: installedForkCommit,
                        mode: mode
                    )
                    await logger.record(Self.logRecord(
                        for: result,
                        attemptIdentifier: attemptIdentifier
                    ))
                    return result
                } catch let failure as ForkUpdateFailure {
                    guard attempt < retryDelays.count, failure.kind == .transient else {
                        await logger.record(
                            Self.logRecord(
                                for: failure,
                                attemptIdentifier: attemptIdentifier,
                                outcome: .failed,
                                retry: attempt
                            )
                        )
                        throw failure
                    }
                    await logger.record(
                        Self.logRecord(
                            for: failure,
                            attemptIdentifier: attemptIdentifier,
                            outcome: .retrying,
                            retry: attempt + 1
                        )
                    )
                    try await sleep(retryDelays[attempt])
                }
            }

            throw ForkUpdateError(message: "VoiceInk exhausted its update retry policy.")
        }.value
    }

    private static func runOnce(
        scriptURL: URL,
        manifestURL: URL,
        installedForkCommit: String?,
        mode: ForkUpdatePreparationMode
    ) throws -> ForkUpdateCommandResult {
        let process = Process()
        process.qualityOfService = mode.isAutomatic ? .utility : .userInitiated
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-update-\(UUID().uuidString).log")
        let resultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-update-\(UUID().uuidString).plist")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: resultURL)
        }
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["VOICEINK_UPDATE_MANIFEST_PATH"] = manifestURL.path
        environment["VOICEINK_UPDATE_RESULT_PATH"] = resultURL.path
        if let installedForkCommit {
            environment["VOICEINK_INSTALLED_FORK_COMMIT"] = installedForkCommit
        } else {
            environment.removeValue(forKey: "VOICEINK_INSTALLED_FORK_COMMIT")
        }
        if mode.retriesSuppressedCandidate {
            environment["VOICEINK_UPDATE_RETRY_SUPPRESSED_CANDIDATE"] = "1"
        } else {
            environment.removeValue(forKey: "VOICEINK_UPDATE_RETRY_SUPPRESSED_CANDIDATE")
        }
        if mode.defersBuild {
            environment["VOICEINK_UPDATE_DEFER_BUILD"] = "1"
        } else {
            environment.removeValue(forKey: "VOICEINK_UPDATE_DEFER_BUILD")
        }
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
            let fallbackMessage = message.flatMap { $0.isEmpty ? nil : $0 }
                ?? "VoiceInk could not prepare the local update."
            if let report = try? PropertyListDecoder().decode(
                Report.self,
                from: Data(contentsOf: resultURL)
            ), report.outcome == "failure" {
                throw failure(from: report, fallbackMessage: fallbackMessage)
            }
            throw ForkUpdateFailure.classify(message: fallbackMessage)
        }

        let report: Report
        do {
            report = try PropertyListDecoder().decode(
                Report.self,
                from: Data(contentsOf: resultURL)
            )
        } catch {
            throw ForkUpdateFailure.classify(
                message: "The local updater finished without recording its result."
            )
        }

        switch report.outcome {
        case "upToDate":
            guard let forkCommit = report.forkCommit, let upstreamCommit = report.upstreamCommit else {
                throw ForkUpdateFailure.classify(
                    message: "The local updater recorded incomplete source provenance."
                )
            }
            return .upToDate(
                SourceProvenance(
                    forkCommit: forkCommit,
                    upstreamCommit: upstreamCommit
                )
            )
        case "buildDeferred":
            return .buildDeferred
        case "candidatePrepared":
            return .candidatePrepared(candidateIdentifier: report.candidateIdentifier)
        case "failureSuppressed":
            return .failureSuppressed(
                failure(
                    from: report,
                    fallbackMessage: "VoiceInk skipped an unchanged failed update stage."
                )
            )
        default:
            throw ForkUpdateFailure.classify(
                message: "The local updater recorded an unknown preparation result."
            )
        }
    }

    private static func failure(from report: Report, fallbackMessage: String) -> ForkUpdateFailure {
        let outputClassification = ForkUpdateFailure.classify(
            message: fallbackMessage,
            defaultStage: report.stage ?? .preflight,
            candidateIdentifier: report.candidateIdentifier
        )
        if outputClassification.kind == .transient {
            return .reported(
                stage: outputClassification.stage,
                kind: .transient,
                candidateIdentifier: report.candidateIdentifier,
                message: report.message ?? "VoiceInk could not reach an update dependency."
            )
        }
        if outputClassification.stage == .toolchain {
            return .reported(
                stage: .toolchain,
                kind: .deterministic,
                candidateIdentifier: report.candidateIdentifier,
                message: "The installed Xcode toolchain is incompatible with this VoiceInk revision."
            )
        }
        let classified = ForkUpdateFailure.classify(
            message: report.message ?? fallbackMessage,
            defaultStage: report.stage ?? outputClassification.stage,
            candidateIdentifier: report.candidateIdentifier
        )
        return .reported(
            stage: report.stage ?? classified.stage,
            kind: report.kind ?? classified.kind,
            candidateIdentifier: report.candidateIdentifier,
            message: report.message ?? fallbackMessage
        )
    }

    private static func logRecord(
        for result: ForkUpdateCommandResult,
        attemptIdentifier: String
    ) -> ForkUpdateLogRecord {
        switch result {
        case .upToDate(let provenance):
            return ForkUpdateLogRecord(
                timestamp: Date(),
                attemptIdentifier: attemptIdentifier,
                stage: .fetch,
                outcome: .succeeded,
                candidateIdentifier: provenance.forkCommit,
                forkCommit: provenance.forkCommit,
                upstreamCommit: provenance.upstreamCommit,
                retry: nil,
                message: nil
            )
        case .buildDeferred:
            return ForkUpdateLogRecord(
                timestamp: Date(),
                attemptIdentifier: attemptIdentifier,
                stage: .build,
                outcome: .succeeded,
                candidateIdentifier: nil,
                forkCommit: nil,
                upstreamCommit: nil,
                retry: nil,
                message: "Build deferred during Low Power Mode."
            )
        case .candidatePrepared(let candidateIdentifier):
            return ForkUpdateLogRecord(
                timestamp: Date(),
                attemptIdentifier: attemptIdentifier,
                stage: .staging,
                outcome: .succeeded,
                candidateIdentifier: candidateIdentifier,
                forkCommit: nil,
                upstreamCommit: nil,
                retry: nil,
                message: nil
            )
        case .failureSuppressed(let failure):
            return logRecord(
                for: failure,
                attemptIdentifier: attemptIdentifier,
                outcome: .suppressed,
                retry: nil
            )
        }
    }

    private static func logRecord(
        for failure: ForkUpdateFailure,
        attemptIdentifier: String,
        outcome: ForkUpdateLogOutcome,
        retry: Int?
    ) -> ForkUpdateLogRecord {
        ForkUpdateLogRecord(
            timestamp: Date(),
            attemptIdentifier: attemptIdentifier,
            stage: failure.stage,
            outcome: outcome,
            candidateIdentifier: failure.candidateIdentifier,
            forkCommit: nil,
            upstreamCommit: nil,
            retry: retry,
            message: failure.message
        )
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
            var environment = ProcessInfo.processInfo.environment
            environment["VOICEINK_UPDATE_CREDENTIAL_GENERATION"] = request.credentialGeneration
            process.environment = environment

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
    private let logger: any ForkUpdateLogging

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
        restorationRunner: any ForkUpdateRestoring = ProcessForkUpdateRestorationRunner(),
        logger: any ForkUpdateLogging = ForkUpdateLogStore.shared
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
        self.logger = logger
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

    func loadPersistentFailure() throws -> ForkUpdateFailure? {
        let failureURL = persistentFailureURL
        guard FileManager.default.fileExists(atPath: failureURL.path) else { return nil }
        return try PropertyListDecoder().decode(
            ForkUpdateFailure.self,
            from: Data(contentsOf: failureURL)
        )
    }

    func persistFailure(_ failure: ForkUpdateFailure) throws {
        let failureURL = persistentFailureURL
        try FileManager.default.createDirectory(
            at: failureURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try PropertyListEncoder().encode(failure).write(to: failureURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: failureURL.path
        )
    }

    func clearPersistentFailure() throws {
        guard FileManager.default.fileExists(atPath: persistentFailureURL.path) else { return }
        try FileManager.default.removeItem(at: persistentFailureURL)
    }

    private var persistentFailureURL: URL {
        manifestURL.deletingLastPathComponent().appendingPathComponent("failure-state.plist")
    }

    func prepare(mode: ForkUpdatePreparationMode) async throws -> ForkUpdatePreparationResult {
        let commandResult = try await commandRunner.run(
            scriptURL: scriptURL,
            manifestURL: manifestURL,
            installedForkCommit: targetBundleURL.flatMap { try? installedForkCommit(at: $0) },
            mode: mode
        )
        switch commandResult {
        case .upToDate(let provenance):
            return .upToDate(provenance)
        case .buildDeferred:
            return .buildDeferred
        case .candidatePrepared:
            break
        case .failureSuppressed(let failure):
            return .failureSuppressed(failure)
        }
        guard let candidate = try loadStagedCandidate() else {
            let failure = ForkUpdateFailure.classify(
                message: "The local updater finished without staging a candidate.",
                defaultStage: .staging
            )
            await record(failure: failure, attemptIdentifier: UUID().uuidString.lowercased())
            throw failure
        }
        await logger.record(
            ForkUpdateLogRecord(
                timestamp: Date(),
                attemptIdentifier: "candidate-\(candidate.forkCommit)",
                stage: .staging,
                outcome: .succeeded,
                candidateIdentifier: "\(candidate.forkCommit):\(candidate.upstreamCommit)",
                forkCommit: candidate.forkCommit,
                upstreamCommit: candidate.upstreamCommit,
                retry: nil,
                message: nil
            )
        )
        return .staged(candidate)
    }

    func requestRestart(for candidate: StagedForkCandidate) async throws -> StagedForkCandidate? {
        guard let stagedCandidate = try loadStagedCandidate() else {
            switch try await prepare(mode: .candidateRevalidation) {
            case .upToDate:
                return nil
            case .buildDeferred:
                throw ForkUpdateError(message: "VoiceInk deferred a user-approved update unexpectedly.")
            case .staged(let candidate):
                return candidate
            case .failureSuppressed(let failure):
                throw failure
            }
        }
        guard stagedCandidate == candidate else {
            return stagedCandidate
        }
        let installationAttempt = "installation-\(candidate.forkCommit)"
        guard let installationScriptURL, let targetBundleURL, let backupBundleURL else {
            let failure = ForkUpdateFailure.classify(
                message: "VoiceInk could not find its local installation helper.",
                defaultStage: .installation,
                candidateIdentifier: candidate.forkCommit
            )
            await record(failure: failure, attemptIdentifier: installationAttempt)
            throw failure
        }
        await logger.record(
            ForkUpdateLogRecord(
                timestamp: Date(),
                attemptIdentifier: installationAttempt,
                stage: .installation,
                outcome: .started,
                candidateIdentifier: candidate.forkCommit,
                forkCommit: candidate.forkCommit,
                upstreamCommit: candidate.upstreamCommit,
                retry: nil,
                message: nil
            )
        )

        let credentialGeneration = UUID().uuidString.lowercased()
        let recoveryIntentURL: URL
        do {
            recoveryIntentURL = try createRecoveryIntent(
                candidate: candidate,
                targetBundleURL: targetBundleURL,
                backupBundleURL: backupBundleURL,
                credentialGeneration: credentialGeneration
            )
        } catch {
            let failure = ForkUpdateFailure.classify(
                message: error.localizedDescription,
                defaultStage: .installation,
                candidateIdentifier: candidate.forkCommit
            )
            await record(failure: failure, attemptIdentifier: installationAttempt)
            throw failure
        }
        do {
            try credentialSnapshotter.createSnapshot(generationIdentifier: credentialGeneration)
        } catch {
            do {
                try removeRecoveryIntentIfPresent(at: recoveryIntentURL)
            } catch {
                let failure = ForkUpdateFailure.classify(
                    message: "VoiceInk could not create the credential snapshot or remove its recovery intent.",
                    defaultStage: .permission,
                    candidateIdentifier: candidate.forkCommit
                )
                await record(failure: failure, attemptIdentifier: installationAttempt)
                throw failure
            }
            let failure = ForkUpdateFailure.classify(
                message: error.localizedDescription,
                defaultStage: .permission,
                candidateIdentifier: candidate.forkCommit
            )
            await record(failure: failure, attemptIdentifier: installationAttempt)
            throw failure
        }

        let request = ForkUpdateInstallationRequest(
            scriptURL: installationScriptURL,
            candidate: candidate,
            manifestURL: manifestURL,
            targetBundleURL: targetBundleURL,
            backupBundleURL: backupBundleURL,
            parentProcessIdentifier: parentProcessIdentifier,
            credentialGeneration: credentialGeneration
        )
        let outcome: ForkUpdateInstallationOutcome
        do {
            outcome = try await installationRunner.install(request)
        } catch {
            do {
                try credentialSnapshotter.deleteSnapshot(generationIdentifier: credentialGeneration)
                try removeRecoveryIntentIfPresent(at: recoveryIntentURL)
            } catch {
                let failure = ForkUpdateFailure.classify(
                    message: "VoiceInk could not install the update or remove its temporary recovery intent.",
                    defaultStage: .installation,
                    candidateIdentifier: candidate.forkCommit
                )
                await record(failure: failure, attemptIdentifier: installationAttempt)
                throw failure
            }
            let failure = (error as? ForkUpdateFailure)
                ?? .classify(
                    message: error.localizedDescription,
                    defaultStage: .installation,
                    candidateIdentifier: candidate.forkCommit
                )
            await record(failure: failure, attemptIdentifier: installationAttempt)
            throw failure
        }
        switch outcome {
        case .completed:
            await logger.record(
                ForkUpdateLogRecord(
                    timestamp: Date(),
                    attemptIdentifier: installationAttempt,
                    stage: .installation,
                    outcome: .succeeded,
                    candidateIdentifier: candidate.forkCommit,
                    forkCommit: candidate.forkCommit,
                    upstreamCommit: candidate.upstreamCommit,
                    retry: nil,
                    message: nil
                )
            )
            return nil
        case .candidateStale:
            await logger.record(
                ForkUpdateLogRecord(
                    timestamp: Date(),
                    attemptIdentifier: installationAttempt,
                    stage: .installation,
                    outcome: .failed,
                    candidateIdentifier: candidate.forkCommit,
                    forkCommit: candidate.forkCommit,
                    upstreamCommit: candidate.upstreamCommit,
                    retry: nil,
                    message: "The approved candidate became stale before installation."
                )
            )
            try credentialSnapshotter.deleteSnapshot(generationIdentifier: credentialGeneration)
            try removeRecoveryIntentIfPresent(at: recoveryIntentURL)
            switch try await prepare(mode: .candidateRevalidation) {
            case .upToDate:
                return nil
            case .buildDeferred:
                throw ForkUpdateError(message: "VoiceInk deferred a user-approved update unexpectedly.")
            case .staged(let candidate):
                return candidate
            case .failureSuppressed(let failure):
                throw failure
            }
        }
    }

    func restorePreviousVersion() async throws {
        let attemptIdentifier = "rollback-\(UUID().uuidString.lowercased())"
        guard
            canRestorePreviousVersion,
            let restorationScriptURL,
            let targetBundleURL,
            let backupBundleURL
        else {
            let failure = ForkUpdateFailure.classify(
                message: "VoiceInk does not have a previous version to restore.",
                defaultStage: .rollback
            )
            await record(failure: failure, attemptIdentifier: attemptIdentifier)
            throw failure
        }
        await logger.record(
            ForkUpdateLogRecord(
                timestamp: Date(),
                attemptIdentifier: attemptIdentifier,
                stage: .rollback,
                outcome: .started,
                candidateIdentifier: nil,
                forkCommit: nil,
                upstreamCommit: nil,
                retry: nil,
                message: nil
            )
        )
        do {
            try await restorationRunner.restore(
                ForkUpdateRestorationRequest(
                    scriptURL: restorationScriptURL,
                    targetBundleURL: targetBundleURL,
                    backupBundleURL: backupBundleURL,
                    parentProcessIdentifier: parentProcessIdentifier
                )
            )
            await logger.record(
                ForkUpdateLogRecord(
                    timestamp: Date(),
                    attemptIdentifier: attemptIdentifier,
                    stage: .rollback,
                    outcome: .succeeded,
                    candidateIdentifier: nil,
                    forkCommit: nil,
                    upstreamCommit: nil,
                    retry: nil,
                    message: nil
                )
            )
        } catch {
            let failure = (error as? ForkUpdateFailure)
                ?? .classify(message: error.localizedDescription, defaultStage: .rollback)
            await record(failure: failure, attemptIdentifier: attemptIdentifier)
            throw failure
        }
    }

    private func record(failure: ForkUpdateFailure, attemptIdentifier: String) async {
        await logger.record(
            ForkUpdateLogRecord(
                timestamp: Date(),
                attemptIdentifier: attemptIdentifier,
                stage: failure.stage,
                outcome: .failed,
                candidateIdentifier: failure.candidateIdentifier,
                forkCommit: nil,
                upstreamCommit: nil,
                retry: nil,
                message: failure.message
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

    private func createRecoveryIntent(
        candidate: StagedForkCandidate,
        targetBundleURL: URL,
        backupBundleURL: URL,
        credentialGeneration: String
    ) throws -> URL {
        let recoveryRoot = backupBundleURL.deletingLastPathComponent()
        let pendingRecovery = URL(fileURLWithPath: recoveryRoot.path + ".pending", isDirectory: true)
        let preparingRecovery = URL(fileURLWithPath: recoveryRoot.path + ".preparing", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: pendingRecovery.path) else {
            throw ForkUpdateError(
                message: "VoiceInk has an unfinished recovery transaction. Relaunch VoiceInk before retrying the update."
            )
        }
        if FileManager.default.fileExists(atPath: preparingRecovery.path) {
            try FileManager.default.removeItem(at: preparingRecovery)
        }

        try FileManager.default.createDirectory(
            at: preparingRecovery,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let state = LocalUpdateRecoveryState(
                previousForkCommit: try installedForkCommit(at: targetBundleURL),
                candidateForkCommit: candidate.forkCommit,
                credentialGeneration: credentialGeneration,
                suppressedForkCommit: nil,
                installInProgress: true,
                restoreInProgress: false
            )
            let stateURL = preparingRecovery.appendingPathComponent("recovery.plist")
            try PropertyListEncoder().encode(state).write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            try FileManager.default.moveItem(at: preparingRecovery, to: pendingRecovery)
            return pendingRecovery
        } catch let creationError {
            do {
                if FileManager.default.fileExists(atPath: preparingRecovery.path) {
                    try FileManager.default.removeItem(at: preparingRecovery)
                }
            } catch {
                throw ForkUpdateError(
                    message: "VoiceInk could not create or remove its temporary recovery intent."
                )
            }
            throw creationError
        }
    }

    private func removeRecoveryIntentIfPresent(at recoveryIntentURL: URL) throws {
        guard FileManager.default.fileExists(atPath: recoveryIntentURL.path) else { return }
        try FileManager.default.removeItem(at: recoveryIntentURL)
    }
}

@MainActor
final class ForkUpdaterAdapter: UpdaterAdapter {
    private enum DefaultsKey {
        static let lastCheckDate = "VoiceInkForkUpdaterLastCheckDate"
    }

    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private(set) var state: UpdaterAdapterState
    var onEvent: ((UpdaterAdapterEvent) -> Void)?

    private let transaction: (any ForkUpdateTransacting)?
    private let powerState: any ForkUpdatePowerStateProviding
    private let defaults: UserDefaults
    private let now: () -> Date
    private var stagedCandidate: StagedForkCandidate?

    init(
        powerState: any ForkUpdatePowerStateProviding = SystemForkUpdatePowerState(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        transaction = nil
        self.powerState = powerState
        self.defaults = defaults
        self.now = now
        state = .unavailable
    }

    init(
        transaction: any ForkUpdateTransacting,
        powerState: any ForkUpdatePowerStateProviding = SystemForkUpdatePowerState(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.transaction = transaction
        self.powerState = powerState
        self.defaults = defaults
        self.now = now
        state = UpdaterAdapterState(
            canCheckForUpdates: true,
            sessionInProgress: false,
            lastUpdateCheckDate: defaults.object(forKey: DefaultsKey.lastCheckDate) as? Date,
            updateCheckInterval: Self.automaticCheckInterval
        )
    }

    var canRestorePreviousVersion: Bool {
        transaction?.canRestorePreviousVersion == true
    }

    func start() {
        onEvent?(.stateChanged(state))
        if let candidate = try? transaction?.loadStagedCandidate() {
            stagedCandidate = candidate
            onEvent?(.stagedCandidate(candidate))
        } else if let failure = try? transaction?.loadPersistentFailure() {
            onEvent?(.preparationFailed(failure))
        }
    }

    func checkForUpdateInformation() {
        startPreparation(mode: .automatic(deferBuild: powerState.isLowPowerModeEnabled))
    }

    func checkForUpdates() {
        startPreparation(mode: .manual)
    }

    private func startPreparation(mode: ForkUpdatePreparationMode) {
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
                switch try await transaction.prepare(mode: mode) {
                case .upToDate(let provenance):
                    try? transaction.clearPersistentFailure()
                    self?.stagedCandidate = nil
                    self?.onEvent?(.forkUpToDate(provenance))
                case .buildDeferred:
                    break
                case .staged(let candidate):
                    try? transaction.clearPersistentFailure()
                    self?.stagedCandidate = candidate
                    self?.onEvent?(.stagedCandidate(candidate))
                case .failureSuppressed(let failure):
                    try? transaction.persistFailure(failure)
                    self?.onEvent?(.preparationFailed(failure))
                }
            } catch {
                let failure = (error as? ForkUpdateFailure)
                    ?? .classify(message: error.localizedDescription)
                try? transaction.persistFailure(failure)
                self?.onEvent?(.preparationFailed(failure))
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
                let failure = (error as? ForkUpdateFailure)
                    ?? .classify(
                        message: error.localizedDescription,
                        defaultStage: .installation,
                        candidateIdentifier: candidate.forkCommit
                    )
                try? transaction.persistFailure(failure)
                self?.onEvent?(.preparationFailed(failure))
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
                try? transaction.clearPersistentFailure()
                self?.onEvent?(.rollbackCompleted)
            } catch {
                let failure = (error as? ForkUpdateFailure)
                    ?? .classify(message: error.localizedDescription, defaultStage: .rollback)
                try? transaction.persistFailure(failure)
                self?.onEvent?(.preparationFailed(failure))
            }
            self?.finishUpdateCycle()
        }
    }

    private func finishUpdateCycle() {
        let completedAt = now()
        defaults.set(completedAt, forKey: DefaultsKey.lastCheckDate)
        state = UpdaterAdapterState(
            canCheckForUpdates: state.canCheckForUpdates,
            sessionInProgress: false,
            lastUpdateCheckDate: completedAt,
            updateCheckInterval: state.updateCheckInterval
        )
        onEvent?(.stateChanged(state))
        onEvent?(.didFinishUpdateCycle)
    }
}
