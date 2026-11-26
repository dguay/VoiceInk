import Foundation
import os

/// Posts paste commands and send keys. Injected so tests never post real key events.
@MainActor
protocol PastePerforming {
    func paste(
        _ text: String,
        sendKey: FinishAndSendKey,
        beforeCommand: (@MainActor () async -> Bool)?
    ) async -> CursorPaster.PasteOutcome
    func performSendKey(_ key: FinishAndSendKey, after outcome: CursorPaster.PasteOutcome) async
}

@MainActor
struct SystemPastePerformer: PastePerforming {
    func paste(
        _ text: String,
        sendKey: FinishAndSendKey,
        beforeCommand: (@MainActor () async -> Bool)?
    ) async -> CursorPaster.PasteOutcome {
        await CursorPaster.startPasteAtCursor(text, sendKey: sendKey, beforeCommand: beforeCommand).value
    }

    func performSendKey(_ key: FinishAndSendKey, after outcome: CursorPaster.PasteOutcome) async {
        if let generation = outcome.autoLearnGeneration {
            await AutoLearnService.shared.cancelForAutoSend(generation: generation)
        }
        CursorPaster.performSendKey(key)
    }
}

/// Shows the finished transcript when automatic delivery did not happen.
@MainActor
protocol PasteRecoveryPresenting: AnyObject {
    func present(text: String, reason: PasteRecoveryReason)
}

enum PasteRecoveryReason: Equatable, Sendable {
    case heldBack(PasteHoldBackReason)
    case notPosted
    case partiallyPosted
    case notLanded
}

/// Outcome of one focus-safe delivery, for callers and tests.
enum FocusSafePasteResult: Equatable, Sendable {
    case pasted(PasteInsertionVerification)
    case recovery(PasteRecoveryReason)
}

/// Delivers a finished dictation without pasting into the wrong place.
/// With the guard off it behaves exactly like the previous fire-and-forget paste.
@MainActor
final class FocusSafePaster {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FocusSafePaster")
    private let focusReader: PasteFocusReading
    private let performer: PastePerforming
    private let recovery: PasteRecoveryPresenting
    private let isGuardEnabled: () -> Bool
    private let sendKeyDelay: TimeInterval
    private let verificationInterval: TimeInterval
    private let verificationTimeout: TimeInterval
    private let sleep: (TimeInterval) async -> Void

    init(
        focusReader: PasteFocusReading = SystemPasteFocusReader.shared,
        performer: PastePerforming? = nil,
        recovery: PasteRecoveryPresenting? = nil,
        isGuardEnabled: @escaping () -> Bool = { PasteFocusGuardSettings.isEnabled() },
        sendKeyDelay: TimeInterval = 0.15,
        verificationInterval: TimeInterval = 0.05,
        verificationTimeout: TimeInterval = 1.0,
        sleep: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.focusReader = focusReader
        self.performer = performer ?? SystemPastePerformer()
        self.recovery = recovery ?? PasteRecoveryCardController.shared
        self.isGuardEnabled = isGuardEnabled
        self.sendKeyDelay = sendKeyDelay
        self.verificationInterval = verificationInterval
        self.verificationTimeout = verificationTimeout
        self.sleep = sleep
    }

    var guardEnabled: Bool { isGuardEnabled() }

    /// Starts reading the delivery target right away. Call when recording finishes,
    /// before transcription or AI cleanup. Returns nil when the guard is off.
    func captureTarget() -> Task<PasteFocusTarget?, Never>? {
        guard isGuardEnabled(), let app = focusReader.frontmostApplication() else { return nil }
        let reader = focusReader
        return Task { await reader.target(processID: app.processID, bundleIdentifier: app.bundleIdentifier) }
    }

    /// Pastes `text` and, when enabled, sends `sendKey`. Holds the paste back and offers the
    /// recovery card when focus moved or is unsafe, or when the delivery failed.
    @discardableResult
    func deliver(_ text: String, sendKey: FinishAndSendKey, captured: PasteFocusTarget?) async -> FocusSafePasteResult {
        guard isGuardEnabled() else {
            return await deliverUnguarded(text, sendKey: sendKey)
        }

        // Quick check before touching the clipboard.
        if case .holdBack(let reason) = await focusReader.decision(captured: captured).decision {
            return holdBack(text, reason: reason)
        }

        let check = PreCommandCheck()
        let reader = focusReader
        let outcome = await performer.paste(text, sendKey: sendKey) {
            // Focus may move during the pre-paste delay, so check again right before the command.
            let (decision, current) = await reader.decision(captured: captured)
            if case .holdBack(let reason) = decision {
                check.holdBack = reason
                return false
            }
            check.element = current?.element
            if let element = check.element {
                check.before = await reader.fieldState(of: element)
            }
            return true
        }
        let before = check.before

        switch outcome.result {
        case .heldBack:
            return holdBack(text, reason: check.holdBack ?? .fieldChanged)
        case .commandNotPosted:
            return showRecovery(text, reason: .notPosted)
        case .commandPartiallyPosted:
            return showRecovery(text, reason: .partiallyPosted)
        case .commandPosted:
            break
        }

        // Verification runs before any send key, so Return never follows a paste that did not land.
        // It returns as soon as the value changes, so the send key keeps its usual delay.
        let verifyStartedAt = ProcessInfo.processInfo.systemUptime
        let verification: PasteInsertionVerification
        if let element = check.element, before != nil {
            verification = await PasteInsertionVerifier.verify(
                before: before,
                insertedText: text,
                pollInterval: verificationInterval,
                timeout: verificationTimeout,
                sleep: sleep,
                readAfter: { await reader.fieldState(of: element) }
            )
        } else {
            verification = .unverified
        }
        if sendKey.isEnabled, verification != .notLanded {
            let remaining = sendKeyDelay - (ProcessInfo.processInfo.systemUptime - verifyStartedAt)
            if remaining > 0 { await sleep(remaining) }
        }

        logger.notice("Focus-safe paste verification=\(String(describing: verification), privacy: .public)")
        if verification == .notLanded {
            return showRecovery(text, reason: .notLanded)
        }
        if sendKey.isEnabled {
            await performer.performSendKey(sendKey, after: outcome)
        }
        return .pasted(verification)
    }

    /// State gathered by the pre-command check, read once the paste session returns.
    @MainActor
    private final class PreCommandCheck {
        var holdBack: PasteHoldBackReason?
        var element: PasteFocusElement?
        var before: PasteFieldState?
    }

    private func deliverUnguarded(_ text: String, sendKey: FinishAndSendKey) async -> FocusSafePasteResult {
        let outcome = await performer.paste(text, sendKey: sendKey, beforeCommand: nil)
        if sendKey.isEnabled && outcome.result.didPostPasteCommand {
            await sleep(sendKeyDelay)
            await performer.performSendKey(sendKey, after: outcome)
        }
        return .pasted(.unverified)
    }

    private func holdBack(_ text: String, reason: PasteHoldBackReason) -> FocusSafePasteResult {
        logger.notice("Focus-safe paste held back reason=\(reason.rawValue, privacy: .public)")
        return showRecovery(text, reason: .heldBack(reason))
    }

    private func showRecovery(_ text: String, reason: PasteRecoveryReason) -> FocusSafePasteResult {
        recovery.present(text: text, reason: reason)
        return .recovery(reason)
    }
}
