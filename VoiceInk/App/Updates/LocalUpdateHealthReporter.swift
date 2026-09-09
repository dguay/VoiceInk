import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

struct LocalUpdatePermissionState: Codable, Equatable, Sendable {
    let microphoneAuthorized: Bool
    let accessibilityAuthorized: Bool
    let screenCaptureAuthorized: Bool
}

protocol LocalUpdatePermissionStateProviding {
    func currentState() -> LocalUpdatePermissionState
}

struct SystemLocalUpdatePermissionStateProvider: LocalUpdatePermissionStateProviding {
    func currentState() -> LocalUpdatePermissionState {
        LocalUpdatePermissionState(
            microphoneAuthorized: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibilityAuthorized: AXIsProcessTrusted(),
            screenCaptureAuthorized: CGPreflightScreenCaptureAccess()
        )
    }
}

struct LocalUpdateHealthReport: Codable, Equatable {
    let forkCommit: String
    let upstreamCommit: String
    let updaterKind: String
    let processIdentifier: Int32
    let permissionState: LocalUpdatePermissionState
}

enum LocalUpdateHealthReporter {
    private static let healthPathArgument = "--voiceink-update-health-path"

    static func isRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.firstIndex(of: healthPathArgument).map { arguments.indices.contains($0 + 1) } == true
    }

    static func reportIfRequested(
        arguments: [String] = CommandLine.arguments,
        bundle: Bundle = .main,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        permissionStateProvider: any LocalUpdatePermissionStateProviding = SystemLocalUpdatePermissionStateProvider()
    ) throws {
        guard
            let argumentIndex = arguments.firstIndex(of: healthPathArgument),
            arguments.indices.contains(argumentIndex + 1),
            let provenance = SourceProvenance.from(bundle: bundle),
            let updaterKind = bundle.object(forInfoDictionaryKey: "VoiceInkUpdaterKind") as? String,
            updaterKind == "fork"
        else {
            return
        }

        let report = LocalUpdateHealthReport(
            forkCommit: provenance.forkCommit,
            upstreamCommit: provenance.upstreamCommit,
            updaterKind: updaterKind,
            processIdentifier: processIdentifier,
            permissionState: permissionStateProvider.currentState()
        )
        let healthURL = URL(fileURLWithPath: arguments[argumentIndex + 1])
        try PropertyListEncoder().encode(report).write(to: healthURL, options: .atomic)
    }
}
