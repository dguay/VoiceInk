import AppKit
import Foundation

@MainActor
protocol AutomaticUpdateScheduling: AnyObject {
    func start(check: @escaping @MainActor () -> Void)
}

@MainActor
final class AutomaticUpdateScheduler: AutomaticUpdateScheduling {
    typealias TimerFactory = (_ interval: TimeInterval, _ action: @escaping () -> Void) -> Timer

    static let staleProbeInterval: TimeInterval = 60 * 60

    private let applicationNotifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private let timerFactory: TimerFactory
    private var applicationObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var check: (@MainActor () -> Void)?

    init(
        applicationNotifications: NotificationCenter = .default,
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        timerFactory: @escaping TimerFactory = { interval, action in
            let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }
    ) {
        self.applicationNotifications = applicationNotifications
        self.workspaceNotifications = workspaceNotifications
        self.timerFactory = timerFactory
    }

    func start(check: @escaping @MainActor () -> Void) {
        guard self.check == nil else { return }
        self.check = check

        applicationObservers.append(
            applicationNotifications.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.runCheck() }
            }
        )
        workspaceObservers.append(
            workspaceNotifications.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.runCheck() }
            }
        )
        timer = timerFactory(Self.staleProbeInterval) { [weak self] in
            Task { @MainActor in self?.runCheck() }
        }

        runCheck()
    }

    func stop() {
        applicationObservers.forEach(applicationNotifications.removeObserver)
        workspaceObservers.forEach(workspaceNotifications.removeObserver)
        applicationObservers.removeAll()
        workspaceObservers.removeAll()
        timer?.invalidate()
        timer = nil
        check = nil
    }

    private func runCheck() {
        check?()
    }

    deinit {
        applicationObservers.forEach(applicationNotifications.removeObserver)
        workspaceObservers.forEach(workspaceNotifications.removeObserver)
        timer?.invalidate()
    }
}
