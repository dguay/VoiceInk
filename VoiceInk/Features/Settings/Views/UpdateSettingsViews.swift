import SwiftUI

/// What the staged candidate contains and how old it is, under the Settings
/// "Update Ready" row. Candidates staged without a summary show only their age.
struct StagedUpdateSummaryView: View {
    let candidate: StagedForkCandidate

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let presentation = StagedUpdatePresentation(candidate: candidate, now: context.date)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: presentation.age)
                    .foregroundStyle(.secondary)
                if let headline = presentation.headline {
                    Text(verbatim: headline)
                }
                ForEach(Array(presentation.subjects.enumerated()), id: \.offset) { _, subject in
                    Text(verbatim: "• \(subject)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(subject)
                }
                if presentation.additionalCommitCount > 0 {
                    Text(verbatim: "…and \(presentation.additionalCommitCount) more")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Installed fork and upstream revisions, a compare link to upstream main,
/// and the automatic check schedule.
struct InstalledSourceView: View {
    let provenance: SourceProvenance
    let state: UpdaterState
    @State private var copiedCommit: String?

    var body: some View {
        LabeledContent("Installed Source") {
            VStack(alignment: .trailing, spacing: 2) {
                commitButton(title: "Fork", commit: provenance.forkCommit, short: provenance.shortForkCommit)
                commitButton(
                    title: "Upstream",
                    commit: provenance.upstreamCommit,
                    short: provenance.shortUpstreamCommit
                )
                Link("Compare with upstream main", destination: provenance.upstreamCompareURL)
                    .font(.caption)
            }
        }

        LabeledContent("Last Update Check") {
            if let lastCheck = state.lastUpdateCheckDate {
                Text(lastCheck, format: .dateTime.month().day().hour().minute())
            } else {
                Text("Never")
            }
        }
        .font(.caption)

        LabeledContent("Next Automatic Check") {
            if !state.checksForUpdatesWhenDashboardAppears {
                Text("Paused")
            } else if let nextCheck = state.nextAutomaticUpdateCheckDate, nextCheck > Date() {
                Text(nextCheck, format: .dateTime.month().day().hour().minute())
            } else {
                Text("Due now")
            }
        }
        .font(.caption)
    }

    private func commitButton(title: String, commit: String, short: String) -> some View {
        Button {
            guard ClipboardManager.copyToClipboard(commit) else { return }
            copiedCommit = commit
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedCommit == commit {
                    copiedCommit = nil
                }
            }
        } label: {
            Text(verbatim: copiedCommit == commit ? "\(title) copied" : "\(title) \(short)")
                .font(.caption.monospaced())
        }
        .buttonStyle(.plain)
        .help("Copy full \(title.lowercased()) SHA \(commit)")
        .accessibilityLabel("\(title) commit \(short)")
        .accessibilityHint("Copies the full commit SHA")
    }
}
