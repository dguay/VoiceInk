import AppKit
import Foundation

struct ForkUpdateUserNotification: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case candidateReady
        case persistentFailure
        case permissionRegression
        case rollbackSucceeded
        case rollbackFailed
    }

    let identifier: String
    let kind: Kind
    let title: String
    let actionLabel: String?
}

@MainActor
protocol ForkUpdateNotificationDelivering: AnyObject {
    func deliver(_ notification: ForkUpdateUserNotification, action: @escaping () -> Void)
}

@MainActor
final class AppForkUpdateNotificationDeliverer: ForkUpdateNotificationDelivering {
    nonisolated init() {}

    func deliver(_ notification: ForkUpdateUserNotification, action: @escaping () -> Void) {
        let type: AppNotificationView.NotificationType
        switch notification.kind {
        case .candidateReady:
            type = .info
        case .rollbackSucceeded:
            type = .success
        case .permissionRegression:
            type = .warning
        case .persistentFailure, .rollbackFailed:
            type = .error
        }
        NotificationManager.shared.showNotification(
            title: notification.title,
            type: type,
            duration: 10,
            actionButton: notification.actionLabel.map { ($0, action) }
        )
    }
}

@MainActor
protocol ForkUpdateLogOpening: AnyObject {
    func openLogs()
}

@MainActor
final class WorkspaceForkUpdateLogOpener: ForkUpdateLogOpening {
    nonisolated init() {}

    func openLogs() {
        try? FileManager.default.createDirectory(
            at: ForkUpdateLogStore.directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        NSWorkspace.shared.open(ForkUpdateLogStore.directoryURL)
    }
}
