import SwiftUI

/// Shows what an in-progress update session is doing. Preparation shows its
/// live stage and elapsed time and offers Cancel; installation cannot be
/// cancelled once it starts.
struct UpdateSessionProgressView: View {
    let activity: UpdaterSessionActivity?
    let cancel: () -> Void

    var body: some View {
        switch activity {
        case .preparing(_, let startedAt):
            HStack(spacing: 8) {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    ProgressView(activity?.statusText(at: context.date) ?? "Preparing…")
                        .controlSize(.small)
                        .monospacedDigit()
                }
                Button("Cancel", action: cancel)
                    .controlSize(.small)
            }
        case .installing, .restoring:
            ProgressView(activity?.statusText(at: Date()) ?? "")
                .controlSize(.small)
        case nil:
            ProgressView("Preparing…")
                .controlSize(.small)
        }
    }
}
