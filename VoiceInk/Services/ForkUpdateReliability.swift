import Foundation

enum ForkUpdateStage: String, Codable, CaseIterable, Sendable {
    case preflight
    case fetch
    case merge
    case test
    case build
    case staging
    case installation
    case health
    case permission
    case rollback
    case toolchain
}

enum ForkUpdateFailureKind: String, Codable, Sendable {
    case transient
    case deterministic
}

struct ForkUpdateFailure: Codable, Equatable, LocalizedError, Sendable {
    let stage: ForkUpdateStage
    let kind: ForkUpdateFailureKind
    let candidateIdentifier: String?
    let message: String
    let recoverySuggestion: String
    let attemptContext: ForkUpdateAttemptContext?

    var errorDescription: String? { message }

    private enum CodingKeys: String, CodingKey {
        case stage
        case kind
        case candidateIdentifier
        case message
        case recoverySuggestion
        case attemptContext
    }

    init(
        stage: ForkUpdateStage,
        kind: ForkUpdateFailureKind,
        candidateIdentifier: String?,
        message: String,
        recoverySuggestion: String,
        attemptContext: ForkUpdateAttemptContext? = nil
    ) {
        self.stage = stage
        self.kind = kind
        self.candidateIdentifier = candidateIdentifier
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.attemptContext = attemptContext
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stage = try container.decode(ForkUpdateStage.self, forKey: .stage)
        let kind = try container.decode(ForkUpdateFailureKind.self, forKey: .kind)
        let candidateIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .candidateIdentifier
        )
        let message = try container.decode(String.self, forKey: .message)
        self = Self.reported(
            stage: stage,
            kind: kind,
            candidateIdentifier: candidateIdentifier,
            message: message,
            recoverySuggestion: try container.decodeIfPresent(
                String.self,
                forKey: .recoverySuggestion
            ),
            attemptContext: try container.decodeIfPresent(
                ForkUpdateAttemptContext.self,
                forKey: .attemptContext
            )
        )
    }

    static func reported(
        stage: ForkUpdateStage,
        kind: ForkUpdateFailureKind,
        candidateIdentifier: String?,
        message: String,
        recoverySuggestion: String? = nil,
        attemptContext: ForkUpdateAttemptContext? = nil
    ) -> ForkUpdateFailure {
        if let recoverySuggestion {
            return ForkUpdateFailure(
                stage: stage,
                kind: kind,
                candidateIdentifier: candidateIdentifier,
                message: message,
                recoverySuggestion: recoverySuggestion,
                attemptContext: attemptContext
            )
        }
        let suggestion: String
        switch stage {
        case .toolchain:
            suggestion = "Install or upgrade Xcode manually, then retry the update."
        case .permission:
            suggestion = "Review VoiceInk's macOS permissions, restore the previous version if needed, then retry."
        case .rollback:
            suggestion = "Open the update logs before retrying the rollback."
        case .health, .installation:
            suggestion = "Restore the previous version or inspect the update logs before retrying."
        default:
            suggestion = kind == .transient
                ? "VoiceInk retried this temporary failure. Check the network, then retry the update."
                : "Open the update logs, correct the failure, then retry the update."
        }
        return ForkUpdateFailure(
            stage: stage,
            kind: kind,
            candidateIdentifier: candidateIdentifier,
            message: message,
            recoverySuggestion: suggestion,
            attemptContext: attemptContext
        )
    }

    func withAttemptContext(_ context: ForkUpdateAttemptContext) -> ForkUpdateFailure {
        ForkUpdateFailure(
            stage: stage,
            kind: kind,
            candidateIdentifier: candidateIdentifier,
            message: message,
            recoverySuggestion: recoverySuggestion,
            attemptContext: context
        )
    }

    static func classify(
        message: String,
        defaultStage: ForkUpdateStage = .preflight,
        candidateIdentifier: String? = nil
    ) -> ForkUpdateFailure {
        let normalized = message.lowercased()
        let transientMarkers = [
            "could not resolve host",
            "network connection was lost",
            "connection reset",
            "connection timed out",
            "connection refused",
            "connection was refused",
            "network is unreachable",
            "remote end hung up",
            "unexpected disconnect",
            "early eof",
            "rpc failed",
            "failed to clone repository",
            "failed downloading",
            "failed to download",
            "package resolution failed",
        ]
        let transientHTTPStatuses = ["http 500", "http 502", "http 503", "http 504"]
        if transientMarkers.contains(where: normalized.contains)
            || transientHTTPStatuses.contains(where: normalized.contains)
        {
            return ForkUpdateFailure(
                stage: defaultStage == .preflight ? .fetch : defaultStage,
                kind: .transient,
                candidateIdentifier: candidateIdentifier,
                message: message,
                recoverySuggestion: "VoiceInk retried this temporary failure. Check the network, then retry the update."
            )
        }

        let toolchainMarkers = [
            "xcode-select",
            "requires xcode",
            "requires a newer xcode",
            "sdk cannot be located",
            "unable to find a destination",
            "developer directory is invalid",
        ]
        if toolchainMarkers.contains(where: normalized.contains) {
            return ForkUpdateFailure(
                stage: .toolchain,
                kind: .deterministic,
                candidateIdentifier: candidateIdentifier,
                message: message,
                recoverySuggestion: "Install or upgrade Xcode manually, then retry the update."
            )
        }

        if normalized.contains("permission") || normalized.contains("authorization") {
            return ForkUpdateFailure(
                stage: .permission,
                kind: .deterministic,
                candidateIdentifier: candidateIdentifier,
                message: message,
                recoverySuggestion: "Review VoiceInk's macOS permissions, restore the previous version if needed, then retry."
            )
        }

        if normalized.contains("rollback") || normalized.contains("restore") {
            return ForkUpdateFailure(
                stage: .rollback,
                kind: .deterministic,
                candidateIdentifier: candidateIdentifier,
                message: message,
                recoverySuggestion: "Open the update logs before retrying the rollback."
            )
        }

        if normalized.contains("health") || normalized.contains("healthy") {
            return ForkUpdateFailure(
                stage: .health,
                kind: .deterministic,
                candidateIdentifier: candidateIdentifier,
                message: message,
                recoverySuggestion: "Restore the previous version or inspect the update logs before retrying."
            )
        }

        return ForkUpdateFailure(
            stage: defaultStage,
            kind: .deterministic,
            candidateIdentifier: candidateIdentifier,
            message: message,
            recoverySuggestion: "Open the update logs, correct the failure, then retry the update."
        )
    }
}

enum ForkUpdateLogOutcome: String, Codable, Sendable {
    case started
    case retrying
    case succeeded
    case failed
    case suppressed
}

struct ForkUpdateLogRecord: Codable, Equatable, Sendable {
    let timestamp: Date
    let attemptIdentifier: String
    let stage: ForkUpdateStage
    let outcome: ForkUpdateLogOutcome
    let candidateIdentifier: String?
    let forkCommit: String?
    let upstreamCommit: String?
    let retry: Int?
    let message: String?
}

protocol ForkUpdateLogging: Sendable {
    func record(_ record: ForkUpdateLogRecord) async
}

actor ForkUpdateLogStore: ForkUpdateLogging {
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    static let maximumBytes = 10 * 1_024 * 1_024
    static let directoryURL: URL = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0]
    .appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
    .appendingPathComponent("Updater", isDirectory: true)
    .appendingPathComponent("Logs", isDirectory: true)
    static let shared = ForkUpdateLogStore(directoryURL: directoryURL)

    private let archive: ForkUpdateLogArchive

    init(
        directoryURL: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        maximumAge: TimeInterval = ForkUpdateLogStore.maximumAge,
        maximumBytes: Int = ForkUpdateLogStore.maximumBytes
    ) {
        archive = ForkUpdateLogArchive(
            directoryURL: directoryURL,
            now: now,
            maximumAge: maximumAge,
            maximumBytes: maximumBytes
        )
    }

    func record(_ record: ForkUpdateLogRecord) async {
        try? archive.record(record)
    }

    func loadRecords() -> [ForkUpdateLogRecord] {
        (try? archive.loadRecords()) ?? []
    }
}

struct ForkUpdateLogArchive {
    private let directoryURL: URL
    private let now: @Sendable () -> Date
    private let maximumAge: TimeInterval
    private let maximumBytes: Int

    init(
        directoryURL: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        maximumAge: TimeInterval = ForkUpdateLogStore.maximumAge,
        maximumBytes: Int = ForkUpdateLogStore.maximumBytes
    ) {
        self.directoryURL = directoryURL
        self.now = now
        self.maximumAge = maximumAge
        self.maximumBytes = maximumBytes
    }

    func record(_ record: ForkUpdateLogRecord) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try encodedLine(for: sanitized(record))
        let url = bundleURL(for: record.attemptIdentifier)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let endOffset = try handle.seekToEnd()
        if endOffset > 0 {
            try handle.seek(toOffset: endOffset - 1)
            let finalByte = try handle.read(upToCount: 1)
            try handle.seekToEnd()
            if finalByte != Data([0x0A]) {
                try handle.write(contentsOf: Data([0x0A]))
            }
        }
        try handle.write(contentsOf: data)
        try prune()
    }

    func loadRecords() throws -> [ForkUpdateLogRecord] {
        try bundleURLs().flatMap { (try? records(in: $0)) ?? [] }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func bundleURL(for attemptIdentifier: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeIdentifier = String(
            attemptIdentifier.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        )
        return directoryURL.appendingPathComponent("attempt-\(safeIdentifier).jsonl")
    }

    private func bundleURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "jsonl" }
    }

    private func records(in url: URL) throws -> [ForkUpdateLogRecord] {
        try Data(contentsOf: url)
            .split(separator: 0x0A)
            .compactMap { try? JSONDecoder().decode(ForkUpdateLogRecord.self, from: Data($0)) }
    }

    private func prune() throws {
        let bundlesWithRecords = try bundleURLs().map { url -> BundleEvidence in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let decoded = (try? records(in: url)) ?? []
            return BundleEvidence(
                url: url,
                date: decoded.map(\.timestamp).max() ?? values.contentModificationDate ?? .distantPast,
                size: values.fileSize ?? 0,
                records: decoded,
                unresolved: false
            )
        }
        let successfulCandidates = bundlesWithRecords
            .flatMap(\.records)
            .filter { $0.outcome == .succeeded && $0.candidateIdentifier != nil }
        var bundles = bundlesWithRecords.map { bundle -> BundleEvidence in
            guard let last = bundle.records.max(by: { $0.timestamp < $1.timestamp }) else {
                return bundle
            }
            let wasResolved = last.candidateIdentifier.map { candidate in
                successfulCandidates.contains {
                    $0.candidateIdentifier == candidate
                        && $0.stage == last.stage
                        && $0.timestamp >= last.timestamp
                }
            } ?? false
            return BundleEvidence(
                url: bundle.url,
                date: bundle.date,
                size: bundle.size,
                records: bundle.records,
                unresolved: last.outcome == .failed && !wasResolved
            )
        }
        let protectedURL = bundles
            .filter(\.unresolved)
            .max(by: { $0.date < $1.date })?
            .url
        let cutoff = now().addingTimeInterval(-maximumAge)

        // Remove expired and then oldest non-protected bundles. If the protected
        // bundle alone exceeds the cap, compact its oldest records instead of losing
        // the newest unresolved failure evidence.
        for bundle in bundles where bundle.date < cutoff && bundle.url != protectedURL {
            try FileManager.default.removeItem(at: bundle.url)
        }
        bundles.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }

        var total = bundles.reduce(0) { $0 + $1.size }
        for bundle in bundles.sorted(by: { $0.date < $1.date })
        where total > maximumBytes && bundle.url != protectedURL {
            try FileManager.default.removeItem(at: bundle.url)
            total -= bundle.size
        }
        if total > maximumBytes, let protectedURL {
            try compactProtectedBundle(at: protectedURL)
        }
    }

    private func compactProtectedBundle(at url: URL) throws {
        let newestFirst = try records(in: url).sorted { $0.timestamp > $1.timestamp }
        var retained: [Data] = []
        var retainedBytes = 0
        for record in newestFirst {
            let line = try encodedLine(for: record)
            guard retainedBytes + line.count <= maximumBytes else { continue }
            retained.append(line)
            retainedBytes += line.count
        }
        let compacted = retained.reversed().reduce(into: Data()) { $0.append($1) }
        try compacted.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func encodedLine(for record: ForkUpdateLogRecord) throws -> Data {
        var data = try JSONEncoder().encode(record)
        data.append(0x0A)
        return data
    }

    private func sanitized(_ record: ForkUpdateLogRecord) -> ForkUpdateLogRecord {
        ForkUpdateLogRecord(
            timestamp: record.timestamp,
            attemptIdentifier: record.attemptIdentifier,
            stage: record.stage,
            outcome: record.outcome,
            candidateIdentifier: record.candidateIdentifier,
            forkCommit: record.forkCommit,
            upstreamCommit: record.upstreamCommit,
            retry: record.retry,
            message: record.message.map(ForkUpdateLogRedactor.sanitize)
        )
    }

    private struct BundleEvidence {
        let url: URL
        let date: Date
        let size: Int
        let records: [ForkUpdateLogRecord]
        let unresolved: Bool
    }
}

struct LocalUpdateInstallationOutcomeReport: Codable, Equatable, Sendable {
    let attemptIdentifier: String
    let candidateIdentifier: String
    let forkCommit: String
    let upstreamCommit: String
    let outcome: ForkUpdateLogOutcome
    let failureStage: ForkUpdateStage?
    let failureKind: ForkUpdateFailureKind?
    let message: String?
    let rollbackOutcome: ForkUpdateLogOutcome?
}

enum LocalUpdateRollbackInitiator: String, Codable, Equatable, Sendable {
    case automatic
    case manual
}

struct LocalUpdateRollbackOutcomeReport: Codable, Equatable, Sendable {
    let attemptIdentifier: String
    let candidateIdentifier: String
    let forkCommit: String?
    let upstreamCommit: String?
    let outcome: ForkUpdateLogOutcome
    let message: String?
    let initiator: LocalUpdateRollbackInitiator
}

struct LocalUpdateRollbackNotice: Codable, Equatable, Sendable {
    let candidateIdentifier: String
    let outcome: ForkUpdateLogOutcome
    let initiator: LocalUpdateRollbackInitiator
}

struct LocalUpdateInstallationOutcomeRecorder {
    private static let installationCommandArgument = "--voiceink-record-update-outcome"
    private static let rollbackCommandArgument = "--voiceink-record-rollback-outcome"
    static let pendingFilename = "install-result.plist"
    static let pendingRollbackFilename = "rollback-result.plist"
    static let failureFilename = "failure-state.plist"
    static let rollbackFilename = "rollback-state.plist"

    private let updaterDirectoryURL: URL
    private let archive: ForkUpdateLogArchive

    init(
        updaterDirectoryURL: URL,
        logDirectoryURL: URL = ForkUpdateLogStore.directoryURL
    ) {
        self.updaterDirectoryURL = updaterDirectoryURL
        archive = ForkUpdateLogArchive(directoryURL: logDirectoryURL)
    }

    static func runIfRequested(arguments: [String] = CommandLine.arguments) throws -> Bool {
        if let reportURL = reportURL(after: installationCommandArgument, in: arguments) {
            try LocalUpdateInstallationOutcomeRecorder(
                updaterDirectoryURL: reportURL.deletingLastPathComponent()
            ).consume(reportAt: reportURL)
            return true
        }
        if let reportURL = reportURL(after: rollbackCommandArgument, in: arguments) {
            try LocalUpdateInstallationOutcomeRecorder(
                updaterDirectoryURL: reportURL.deletingLastPathComponent()
            ).consumeRollback(reportAt: reportURL)
            return true
        }
        return false
    }

    static func consumePendingForLaunch() {
        let updaterDirectory = ForkUpdateLogStore.directoryURL.deletingLastPathComponent()
        LocalUpdateInstallationOutcomeRecorder(
            updaterDirectoryURL: updaterDirectory
        ).consumePendingForLaunch()
    }

    func consume(reportAt reportURL: URL) throws {
        let report = try PropertyListDecoder().decode(
            LocalUpdateInstallationOutcomeReport.self,
            from: Data(contentsOf: reportURL)
        )
        try record(report)
        try FileManager.default.removeItem(at: reportURL)
    }

    func consumeRollback(reportAt reportURL: URL) throws {
        let report = try PropertyListDecoder().decode(
            LocalUpdateRollbackOutcomeReport.self,
            from: Data(contentsOf: reportURL)
        )
        try record(report)
        try FileManager.default.removeItem(at: reportURL)
    }

    func consumePendingForLaunch() {
        consumeForLaunch(
            filename: Self.pendingFilename,
            invalidFilename: "install-result.invalid.plist",
            as: LocalUpdateInstallationOutcomeReport.self,
            record: record
        )
        consumeForLaunch(
            filename: Self.pendingRollbackFilename,
            invalidFilename: "rollback-result.invalid.plist",
            as: LocalUpdateRollbackOutcomeReport.self,
            record: record
        )
    }

    private func record(_ report: LocalUpdateInstallationOutcomeReport) throws {
        try FileManager.default.createDirectory(
            at: updaterDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try archive.record(logRecord(stage: .installation, outcome: report.outcome, report: report))
        if report.outcome == .failed {
            let stage = report.failureStage ?? .installation
            let failure = ForkUpdateFailure.reported(
                stage: stage,
                kind: report.failureKind ?? .deterministic,
                candidateIdentifier: report.candidateIdentifier,
                message: report.message ?? "VoiceInk could not install the local update."
            )
            if stage != .installation {
                try archive.record(logRecord(stage: stage, outcome: .failed, report: report))
            }
            try write(failure, filename: Self.failureFilename)
        }
        if let rollbackOutcome = report.rollbackOutcome {
            try archive.record(logRecord(stage: .rollback, outcome: rollbackOutcome, report: report))
            try write(
                LocalUpdateRollbackNotice(
                    candidateIdentifier: report.candidateIdentifier,
                    outcome: rollbackOutcome,
                    initiator: .automatic
                ),
                filename: Self.rollbackFilename
            )
        }
    }

    private func record(_ report: LocalUpdateRollbackOutcomeReport) throws {
        try FileManager.default.createDirectory(
            at: updaterDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try archive.record(
            ForkUpdateLogRecord(
                timestamp: Date(),
                attemptIdentifier: report.attemptIdentifier,
                stage: .rollback,
                outcome: report.outcome,
                candidateIdentifier: report.candidateIdentifier,
                forkCommit: report.forkCommit,
                upstreamCommit: report.upstreamCommit,
                retry: nil,
                message: report.message
            )
        )
        if report.outcome == .failed {
            try write(
                ForkUpdateFailure.reported(
                    stage: .rollback,
                    kind: .deterministic,
                    candidateIdentifier: report.candidateIdentifier,
                    message: report.message ?? "VoiceInk could not restore the previous version."
                ),
                filename: Self.failureFilename
            )
        } else if report.initiator == .manual {
            try removeIfPresent(filename: Self.failureFilename)
        }
        try write(
            LocalUpdateRollbackNotice(
                candidateIdentifier: report.candidateIdentifier,
                outcome: report.outcome,
                initiator: report.initiator
            ),
            filename: Self.rollbackFilename
        )
    }

    private func logRecord(
        stage: ForkUpdateStage,
        outcome: ForkUpdateLogOutcome,
        report: LocalUpdateInstallationOutcomeReport
    ) -> ForkUpdateLogRecord {
        ForkUpdateLogRecord(
            timestamp: Date(),
            attemptIdentifier: report.attemptIdentifier,
            stage: stage,
            outcome: outcome,
            candidateIdentifier: report.candidateIdentifier,
            forkCommit: report.forkCommit,
            upstreamCommit: report.upstreamCommit,
            retry: nil,
            message: report.message
        )
    }

    private func write(_ value: some Encodable, filename: String) throws {
        let url = updaterDirectoryURL.appendingPathComponent(filename)
        try PropertyListEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func consumeForLaunch<Report: Decodable>(
        filename: String,
        invalidFilename: String,
        as _: Report.Type,
        record: (Report) throws -> Void
    ) {
        let url = updaterDirectoryURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let report: Report
        do {
            report = try PropertyListDecoder().decode(Report.self, from: Data(contentsOf: url))
        } catch {
            quarantineInvalidReport(at: url, filename: invalidFilename)
            return
        }
        do {
            try record(report)
            try FileManager.default.removeItem(at: url)
        } catch {
            // Evidence import is retried next launch, but must never block recovery or app startup.
        }
    }

    private func quarantineInvalidReport(at url: URL, filename: String) {
        let invalidURL = updaterDirectoryURL.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: invalidURL)
        try? FileManager.default.moveItem(at: url, to: invalidURL)
    }

    private func removeIfPresent(filename: String) throws {
        let url = updaterDirectoryURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func reportURL(after argument: String, in arguments: [String]) -> URL? {
        guard
            let index = arguments.firstIndex(of: argument),
            arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }
}
