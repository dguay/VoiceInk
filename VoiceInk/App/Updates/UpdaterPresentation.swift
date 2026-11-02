import AppKit
import Foundation

/// Brings updater UI forward, including from a menu-bar-only session with no
/// visible window, so a notification action never lands on nothing.
@MainActor
protocol UpdaterWindowPresenting: AnyObject {
    func showMainWindow()
    func showUpdateSettings()
}

@MainActor
final class AppUpdaterWindowPresenter: UpdaterWindowPresenting {
    nonisolated init() {}

    func showMainWindow() {
        NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
    }

    func showUpdateSettings() {
        MainWindowNavigation.shared.openUpdateSettings()
        showMainWindow()
    }
}

@MainActor
protocol ForkUpdateRepositoryOpening: AnyObject {
    func openRepository(at url: URL)
}

@MainActor
final class WorkspaceForkUpdateRepositoryOpener: ForkUpdateRepositoryOpening {
    nonisolated init() {}

    func openRepository(at url: URL) {
        NSWorkspace.shared.open(url)
    }
}

extension ForkUpdateStage {
    var displayName: String {
        switch self {
        case .preflight: "Preflight"
        case .fetch: "Fetch"
        case .merge: "Merge"
        case .test: "Test"
        case .build: "Build"
        case .staging: "Staging"
        case .installation: "Installation"
        case .health: "Health check"
        case .permission: "Permissions"
        case .publication: "Publication"
        case .rollback: "Rollback"
        case .toolchain: "Toolchain"
        }
    }
}

extension ForkUpdateFailure {
    /// Files the preparation helper recorded as conflicted for a merge failure.
    var conflictedFiles: [String] {
        attemptContext?.conflicts ?? []
    }

    /// The registered clone the failed attempt ran against, when known.
    var repositoryURL: URL? {
        guard let path = attemptContext?.repositoryPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

extension SourceProvenance {
    static let upstreamRepositoryURL = URL(string: "https://github.com/Beingpax/VoiceInk")!
    static let shortCommitLength = 12

    var shortForkCommit: String { String(forkCommit.prefix(Self.shortCommitLength)) }
    var shortUpstreamCommit: String { String(upstreamCommit.prefix(Self.shortCommitLength)) }

    /// Upstream changes the installed app does not contain yet.
    var upstreamCompareURL: URL {
        Self.upstreamRepositoryURL.appendingPathComponent("compare/\(upstreamCommit)...main")
    }
}

/// Text the Update Ready alert and the Settings row show for a staged candidate.
struct StagedUpdatePresentation: Equatable {
    static let defaultMaximumSubjects = 5
    static let maximumSubjectLength = 120

    let shortForkCommit: String
    let headline: String?
    let subjects: [String]
    let additionalCommitCount: Int
    let relativeAge: String

    init(
        candidate: StagedForkCandidate,
        now: Date = Date(),
        maximumSubjects: Int = StagedUpdatePresentation.defaultMaximumSubjects
    ) {
        shortForkCommit = String(candidate.forkCommit.prefix(SourceProvenance.shortCommitLength))
        relativeAge = Self.relativeAge(from: candidate.preparedAt, to: now)
        if let summary = candidate.changeSummary {
            let count = max(summary.upstreamCommitCount, 0)
            headline = count == 1
                ? "1 upstream commit since the installed version"
                : "\(count) upstream commits since the installed version"
            subjects = summary.upstreamCommitSubjects
                .prefix(max(maximumSubjects, 0))
                .map { subject in
                    guard subject.count > Self.maximumSubjectLength else { return subject }
                    return String(subject.prefix(Self.maximumSubjectLength - 1)) + "…"
                }
            additionalCommitCount = max(count - subjects.count, 0)
        } else {
            headline = nil
            subjects = []
            additionalCommitCount = 0
        }
    }

    var age: String { "Prepared \(relativeAge)" }

    var message: String {
        var lines = ["VoiceInk prepared fork commit \(shortForkCommit) \(relativeAge)."]
        guard let headline else { return lines[0] }
        lines.append("")
        lines.append(subjects.isEmpty && additionalCommitCount == 0 ? headline + "." : headline + ":")
        lines.append(contentsOf: subjects.map { "• \($0)" })
        if additionalCommitCount > 0 {
            lines.append("…and \(additionalCommitCount) more")
        }
        return lines.joined(separator: "\n")
    }

    private static func relativeAge(from preparedAt: Date, to now: Date) -> String {
        let elapsed = now.timeIntervalSince(preparedAt)
        let minute: TimeInterval = 60
        let hour = 60 * minute
        let day = 24 * hour
        func count(_ value: Int, _ unit: String) -> String {
            "\(value) \(unit)\(value == 1 ? "" : "s") ago"
        }
        switch elapsed {
        case ..<minute:
            return "just now"
        case ..<hour:
            return count(Int(elapsed / minute), "minute")
        case ..<day:
            return count(Int(elapsed / hour), "hour")
        default:
            return count(Int(elapsed / day), "day")
        }
    }
}
