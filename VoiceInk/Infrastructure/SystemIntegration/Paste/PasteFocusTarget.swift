import Foundation

/// Persisted switch for focus-safe paste. On by default.
enum PasteFocusGuardSettings {
    static let key = "PasteFocusGuardEnabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// Opaque identity of an Accessibility object (window or focused element).
/// Two identities are equal when CoreFoundation reports the wrapped objects as equal,
/// which is how `AXUIElement` references are compared.
struct PasteFocusIdentity: Equatable, @unchecked Sendable {
    let object: AnyObject

    init(_ object: AnyObject) {
        self.object = object
    }

    static func == (lhs: PasteFocusIdentity, rhs: PasteFocusIdentity) -> Bool {
        CFEqual(lhs.object as CFTypeRef, rhs.object as CFTypeRef)
    }
}

/// The focused UI element as far as Accessibility reports it. Nil fields are unknown.
struct PasteFocusElement: Equatable, Sendable {
    static let secureTextFieldRole = "AXSecureTextField"

    let identity: PasteFocusIdentity
    var role: String?
    var subrole: String?
    /// Nil means editability is unknown (generic containers, web views).
    var editable: Bool?

    var isSecure: Bool {
        role == Self.secureTextFieldRole || subrole == Self.secureTextFieldRole
    }
}

/// Where a dictation should land: the frontmost application, its focused window and
/// focused element when Accessibility exposes them.
struct PasteFocusTarget: Equatable, Sendable {
    let processID: pid_t
    let bundleIdentifier: String?
    var window: PasteFocusIdentity?
    var element: PasteFocusElement?
}

/// Readable state of a text field, used to verify whether a paste landed.
struct PasteFieldState: Equatable, Sendable {
    let value: String
    var selectedText: String?
}

enum PasteHoldBackReason: String, Equatable, Sendable {
    case applicationChanged
    case windowChanged
    case fieldChanged
    case secureField
    case notEditable
}

enum PasteFocusDecision: Equatable, Sendable {
    case proceed
    case holdBack(PasteHoldBackReason)
}

/// Pure decision: may an automatic paste go to `current`, given the target captured
/// when recording finished? Unknown state is never treated as unsafe.
enum PasteFocusGuard {
    /// - Parameter capturedElementStillFocused: Whether the captured element still reports
    ///   itself focused. Some apps (Chromium) hand out a new object for the same field once
    ///   web accessibility turns on, so a different identity only counts as a move when the
    ///   captured element does not confirm it still has focus.
    static func decide(
        captured: PasteFocusTarget?,
        current: PasteFocusTarget?,
        capturedElementStillFocused: Bool? = nil
    ) -> PasteFocusDecision {
        if let element = current?.element {
            if element.isSecure { return .holdBack(.secureField) }
        }

        if let captured, let current {
            if captured.processID != current.processID { return .holdBack(.applicationChanged) }
            if let capturedWindow = captured.window, let currentWindow = current.window,
                capturedWindow != currentWindow
            {
                return .holdBack(.windowChanged)
            }
            if let capturedElement = captured.element, let currentElement = current.element,
                capturedElement.identity != currentElement.identity,
                capturedElementStillFocused != true
            {
                return .holdBack(.fieldChanged)
            }
        }

        if current?.element?.editable == false { return .holdBack(.notEditable) }
        return .proceed
    }
}

enum PasteInsertionVerification: Equatable, Sendable {
    case landed
    case notLanded
    case unverified
}

/// Compares a field's readable value before and after a paste. Only a field that stays
/// readable and unchanged until the deadline counts as `notLanded`.
enum PasteInsertionVerifier {
    /// Very large values are expensive to poll and are left unverified.
    static let maximumValueLength = 200_000

    static func verify(
        before: PasteFieldState?,
        insertedText: String,
        pollInterval: TimeInterval = 0.05,
        timeout: TimeInterval = 1.0,
        sleep: (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        readAfter: () async -> PasteFieldState?
    ) async -> PasteInsertionVerification {
        guard let before, before.value.utf16.count <= maximumValueLength,
            !insertedText.isEmpty
        else { return .unverified }
        // Replacing a selection with identical text leaves the value unchanged.
        if let selected = before.selectedText, !selected.isEmpty, selected == insertedText {
            return .unverified
        }

        let attempts = max(1, Int((timeout / max(pollInterval, 0.001)).rounded(.up)))
        for _ in 0..<attempts {
            await sleep(pollInterval)
            guard let after = await readAfter(), after.value.utf16.count <= maximumValueLength else {
                return .unverified
            }
            if after.value != before.value { return .landed }
        }
        return .notLanded
    }
}
