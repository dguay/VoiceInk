import AppKit
import ApplicationServices
import Foundation

/// Reads delivery focus. Implementations must never log field values.
protocol PasteFocusReading: Sendable {
    /// The frontmost application, read synchronously (no Accessibility queries).
    @MainActor func frontmostApplication() -> (processID: pid_t, bundleIdentifier: String?)?
    /// Focused window and element of `processID`, when Accessibility exposes them.
    func target(processID: pid_t, bundleIdentifier: String?) async -> PasteFocusTarget
    /// Readable value of a focused element, or nil when it is unavailable.
    func fieldState(of element: PasteFocusElement) async -> PasteFieldState?
    /// Whether `element` still reports itself focused, or nil when that is unknown.
    func isFocused(_ element: PasteFocusElement) async -> Bool?
}

extension PasteFocusReading {
    @MainActor
    func currentTarget() async -> PasteFocusTarget? {
        guard let app = frontmostApplication() else { return nil }
        return await target(processID: app.processID, bundleIdentifier: app.bundleIdentifier)
    }

    /// Reads the current target and decides whether an automatic paste may go there.
    @MainActor
    func decision(captured: PasteFocusTarget?) async -> (decision: PasteFocusDecision, current: PasteFocusTarget?) {
        let current = await currentTarget()
        var decision = PasteFocusGuard.decide(captured: captured, current: current)
        if decision == .holdBack(.fieldChanged), let element = captured?.element {
            let stillFocused = await isFocused(element)
            decision = PasteFocusGuard.decide(
                captured: captured, current: current, capturedElementStillFocused: stillFocused)
        }
        return (decision, current)
    }
}

/// Accessibility-backed focus reader. Queries run off the main thread with short
/// per-request timeouts; no tree walks and no web accessibility toggling.
final class SystemPasteFocusReader: PasteFocusReading, @unchecked Sendable {
    static let shared = SystemPasteFocusReader()

    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.paste-focus-guard", qos: .userInitiated)
    private let messagingTimeout: Float = 0.03

    @MainActor
    func frontmostApplication() -> (processID: pid_t, bundleIdentifier: String?)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return (app.processIdentifier, app.bundleIdentifier)
    }

    func target(processID: pid_t, bundleIdentifier: String?) async -> PasteFocusTarget {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: readTarget(processID: processID, bundleIdentifier: bundleIdentifier))
            }
        }
    }

    func fieldState(of element: PasteFocusElement) async -> PasteFieldState? {
        guard CFGetTypeID(element.identity.object as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                let axElement = unsafeBitCast(element.identity.object as CFTypeRef, to: AXUIElement.self)
                guard AXIsProcessTrusted() else {
                    continuation.resume(returning: nil)
                    return
                }
                guard
                    let value = AccessibilityFocusReader.stringAttribute(kAXValueAttribute as CFString, from: axElement)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                let selected = AccessibilityFocusReader.stringAttribute(
                    kAXSelectedTextAttribute as CFString, from: axElement)
                continuation.resume(returning: PasteFieldState(value: value, selectedText: selected))
            }
        }
    }

    func isFocused(_ element: PasteFocusElement) async -> Bool? {
        guard CFGetTypeID(element.identity.object as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                let axElement = unsafeBitCast(element.identity.object as CFTypeRef, to: AXUIElement.self)
                guard AXIsProcessTrusted() else {
                    continuation.resume(returning: nil)
                    return
                }
                AXUIElementSetMessagingTimeout(axElement, messagingTimeout)
                continuation.resume(
                    returning: AccessibilityFocusReader.boolAttribute(kAXFocusedAttribute as CFString, from: axElement))
            }
        }
    }

    private func readTarget(processID: pid_t, bundleIdentifier: String?) -> PasteFocusTarget {
        var target = PasteFocusTarget(processID: processID, bundleIdentifier: bundleIdentifier)
        // Querying our own process from a background queue can wait on the main thread.
        guard AXIsProcessTrusted(), processID != ProcessInfo.processInfo.processIdentifier else { return target }

        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        if let window = elementAttribute(kAXFocusedWindowAttribute as CFString, of: app) {
            target.window = PasteFocusIdentity(window)
        }
        if let element = AccessibilityFocusReader.focusedElement(in: app).element {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            let role = AccessibilityFocusReader.stringAttribute(kAXRoleAttribute as CFString, from: element)
            let subrole = AccessibilityFocusReader.stringAttribute(kAXSubroleAttribute as CFString, from: element)
            let editable = AccessibilityFocusReader.editableState(of: element, role: role)
            target.element = PasteFocusElement(
                identity: PasteFocusIdentity(element), role: role, subrole: subrole, editable: editable)
        }
        return target
    }

    private func elementAttribute(_ attribute: CFString, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
