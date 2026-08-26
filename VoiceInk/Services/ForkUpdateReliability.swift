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

    var errorDescription: String? { message }

    private enum CodingKeys: String, CodingKey {
        case stage
        case kind
        case candidateIdentifier
        case message
        case recoverySuggestion
    }

    init(
        stage: ForkUpdateStage,
        kind: ForkUpdateFailureKind,
        candidateIdentifier: String?,
        message: String,
        recoverySuggestion: String
    ) {
        self.stage = stage
        self.kind = kind
        self.candidateIdentifier = candidateIdentifier
        self.message = message
        self.recoverySuggestion = recoverySuggestion
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
            )
        )
    }

    static func reported(
        stage: ForkUpdateStage,
        kind: ForkUpdateFailureKind,
        candidateIdentifier: String?,
        message: String,
        recoverySuggestion: String? = nil
    ) -> ForkUpdateFailure {
        if let recoverySuggestion {
            return ForkUpdateFailure(
                stage: stage,
                kind: kind,
                candidateIdentifier: candidateIdentifier,
                message: message,
                recoverySuggestion: recoverySuggestion
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
            recoverySuggestion: suggestion
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
            "failed downloading",
            "failed to download",
            "package resolution failed",
        ]
        if transientMarkers.contains(where: normalized.contains) {
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

    private let directoryURL: URL
    private let now: @Sendable () -> Date
    private let maximumAge: TimeInterval
    private let maximumBytes: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

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

    func record(_ record: ForkUpdateLogRecord) async {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let sanitized = ForkUpdateLogRecord(
                timestamp: record.timestamp,
                attemptIdentifier: record.attemptIdentifier,
                stage: record.stage,
                outcome: record.outcome,
                candidateIdentifier: record.candidateIdentifier,
                forkCommit: record.forkCommit,
                upstreamCommit: record.upstreamCommit,
                retry: record.retry,
                message: record.message.map(Self.sanitize)
            )
            var data = try encoder.encode(sanitized)
            data.append(0x0A)
            let url = bundleURL(for: sanitized.attemptIdentifier)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try prune()
        } catch {
            // Updater evidence must never make an update operation fail.
        }
    }

    func loadRecords() -> [ForkUpdateLogRecord] {
        (try? bundleURLs().flatMap(records(in:)))?
            .sorted { $0.timestamp < $1.timestamp } ?? []
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
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? decoder.decode(ForkUpdateLogRecord.self, from: Data($0.utf8)) }
    }

    private func prune() throws {
        let decodedBundles = try bundleURLs().compactMap { url -> (URL, [ForkUpdateLogRecord], Int)? in
            let records = try records(in: url)
            guard !records.isEmpty else { return nil }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return (url, records, size)
        }
        let successfulCandidates = decodedBundles
            .flatMap { $0.1 }
            .filter { $0.outcome == .succeeded && $0.candidateIdentifier != nil }
        var bundles = decodedBundles.compactMap { url, records, size -> BundleEvidence? in
            guard let last = records.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
            let wasResolved = last.candidateIdentifier.map { candidate in
                successfulCandidates.contains {
                    $0.candidateIdentifier == candidate && $0.timestamp >= last.timestamp
                }
            } ?? false
            return BundleEvidence(
                url: url,
                date: last.timestamp,
                size: size,
                unresolved: last.outcome == .failed && !wasResolved
            )
        }
        let protectedURL = bundles
            .filter(\.unresolved)
            .max(by: { $0.date < $1.date })?
            .url
        let cutoff = now().addingTimeInterval(-maximumAge)

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
    }

    private static func sanitize(_ message: String) -> String {
        var sanitized = String(message.prefix(2_048))
        let patterns = [
            "(?i)bearer\\s+[^\\s,;]+",
            "(?i)(authorization|api[_-]?key|token|secret|password|credential|transcript|selected[_-]?text|screenshot|clipboard)(\\s*[:=]\\s*|\\s+)[^\\s,;]+",
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = expression.stringByReplacingMatches(
                in: sanitized,
                range: range,
                withTemplate: "$1=[REDACTED]"
            )
        }
        return sanitized
    }

    private struct BundleEvidence {
        let url: URL
        let date: Date
        let size: Int
        let unresolved: Bool
    }
}
