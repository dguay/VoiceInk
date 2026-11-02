import AppKit
import Foundation

/// Explains why "Restart and Update" must wait for the engine to become idle.
enum UpdateRestartGuard {
    static func blockingReason(for recordingState: RecordingState) -> String? {
        switch recordingState {
        case .idle:
            return nil
        case .starting, .recording:
            return "VoiceInk is recording. Restart and Update is available when the recording finishes."
        case .transcribing:
            return "VoiceInk is transcribing. Restart and Update is available when the transcription finishes."
        case .enhancing:
            return "VoiceInk is enhancing a transcription. Restart and Update is available when enhancement finishes."
        case .busy:
            return "VoiceInk is finishing a transcription. Restart and Update is available when it is idle."
        }
    }

    static let fileTranscriptionReason =
        "VoiceInk is transcribing or enhancing a saved recording. Restart and Update is available when it finishes."

    /// Engine activity wins; imported-audio and history retranscription work also blocks.
    static func blockingReason(for recordingState: RecordingState, fileTranscriptionActive: Bool) -> String? {
        blockingReason(for: recordingState) ?? (fileTranscriptionActive ? fileTranscriptionReason : nil)
    }
}

/// Counts work that runs outside the engine (imported audio queue, history
/// retranscription and history re-enhancement), so installation never quits
/// VoiceInk before that work has finished and saved its result.
@MainActor
final class FileTranscriptionActivity: ObservableObject {
    static let shared = FileTranscriptionActivity()

    @Published private(set) var isActive = false
    private var activeCount = 0

    func begin() {
        activeCount += 1
        isActive = true
    }

    func end() {
        activeCount = max(0, activeCount - 1)
        isActive = activeCount > 0
    }
}

/// App-wide record of the engine activity that blocks quitting for installation.
/// The installer's quit request is answered from this state on the main thread.
@MainActor
final class UpdateRestartGate {
    static let shared = UpdateRestartGate()

    var blockingReason: String?
}

/// The app's answer to the installer's graceful quit request.
enum ForkUpdateQuitResponse: String, Sendable {
    /// VoiceInk is idle and is quitting through its normal termination path.
    case quit
    /// VoiceInk is recording, transcribing, or enhancing; the installer cancels.
    case busy
}

protocol ForkUpdateQuitRequestHandling: Sendable {
    /// Answers the installer's quit request. `respond` must be called exactly once
    /// before the app starts terminating so the installer never signals a busy app.
    func handleQuitRequest(respond: (ForkUpdateQuitResponse) -> Void)
}

struct ApplicationForkUpdateQuitRequestHandler: ForkUpdateQuitRequestHandling {
    func handleQuitRequest(respond: (ForkUpdateQuitResponse) -> Void) {
        if Thread.isMainThread {
            Self.decide(respond: respond)
        } else {
            DispatchQueue.main.sync { Self.decide(respond: respond) }
        }
    }

    // Decide and start termination in one main-thread turn so a recording cannot
    // start between the idle check and the quit. NSApplication.terminate runs the
    // normal termination hooks, so model contexts save and panels close.
    private static func decide(respond: (ForkUpdateQuitResponse) -> Void) {
        MainActor.assumeIsolated {
            guard UpdateRestartGate.shared.blockingReason == nil else {
                respond(.busy)
                return
            }
            respond(.quit)
            NSApplication.shared.terminate(nil)
        }
    }
}

/// The installer stopped before quitting VoiceInk because it became busy.
struct ForkUpdateRestartCancellation: LocalizedError, Equatable {
    static let busy = ForkUpdateRestartCancellation(
        message: "VoiceInk did not restart because a recording, transcription, or enhancement started. The update is still ready; VoiceInk offers it again when idle."
    )

    let message: String

    var errorDescription: String? { message }
}
