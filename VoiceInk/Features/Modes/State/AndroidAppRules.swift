import Foundation

/// Editing the Android app rules of a mode draft.
extension Array where Element == AndroidAppConfig {
    /// Whether a rule names `packageName`.
    func containsRule(for packageName: String) -> Bool {
        contains { $0.packageName == packageName }
    }

    /// Adds a rule for `packageName` (trimmed, validated like the `app` parameter of
    /// `POST /v1/transcribe`) with the optional readable `appName`. Returns `false`, changing
    /// nothing, when the package name is invalid or already has a rule.
    @discardableResult
    mutating func addRule(packageName: String, appName: String? = nil) -> Bool {
        let trimmed = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let valid = PhoneDictationRequestContext.validatedApp(trimmed), !containsRule(for: valid) else {
            return false
        }
        append(
            AndroidAppConfig(
                packageName: valid, appName: appName.flatMap(PhoneDictationRequestContext.validatedAppName)))
        return true
    }

    /// Removes every rule for `packageName`.
    mutating func removeRule(for packageName: String) {
        removeAll { $0.packageName == packageName }
    }
}
