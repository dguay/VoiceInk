import Foundation

/// The kind of field the phone is typing into, sent as `field` on `POST /v1/transcribe`.
enum PhoneDictationFieldKind: String, CaseIterable, Equatable {
    case text
    case email
    case url
    case number
    case other

    /// Email addresses, URLs and numbers get the transcription without AI cleanup or paragraph
    /// formatting, so nothing rewrites what was spelled out.
    var skipsAIEnhancementAndFormatting: Bool {
        switch self {
        case .email, .url, .number: return true
        case .text, .other: return false
        }
    }
}

/// What the phone tells the Mac about where the text goes. All values are optional in API v1.
struct PhoneDictationRequestContext: Equatable {
    /// The Android package name of the app being typed into, or `nil` when absent or malformed.
    var app: String?
    /// The field kind, or `nil` when absent. An unknown value is `.other`.
    var field: PhoneDictationFieldKind?
    /// The readable name of `app` as the phone shows it (its launcher label), or `nil` when absent,
    /// unusable, or sent without a valid `app`.
    var appName: String?

    static let empty = PhoneDictationRequestContext(app: nil, field: nil)

    /// Longest accepted `app` value, in characters.
    static let maxAppLength = 255
    /// Longest accepted `appName` value, in characters.
    static let maxAppNameLength = 100

    init(app: String?, field: PhoneDictationFieldKind?, appName: String? = nil) {
        self.app = app
        self.field = field
        self.appName = app == nil ? nil : appName
    }

    /// Reads `app`, `field` and `appName` from the query of a transcribe request. A malformed `app`
    /// or `appName` is ignored (the request runs as if it had none), it never fails the request.
    init(query: [String: String]) {
        self.app = query["app"].flatMap(Self.validatedApp)
        self.field = query["field"].map { value in
            PhoneDictationFieldKind(rawValue: value.trimmingCharacters(in: .whitespaces).lowercased()) ?? .other
        }
        self.appName = app == nil ? nil : query["appName"].flatMap(Self.validatedAppName)
    }

    /// Whether this request skips AI enhancement and paragraph formatting.
    var skipsAIEnhancementAndFormatting: Bool {
        field?.skipsAIEnhancementAndFormatting ?? false
    }

    /// `value` when it is a plausible Android package name (dot-separated segments of letters,
    /// digits and underscores, each starting with a letter, at most 255 characters), else `nil`.
    static func validatedApp(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= maxAppLength else { return nil }
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        let isValid = segments.allSatisfy { segment in
            guard let first = segment.first, first.isASCII, first.isLetter else { return false }
            return segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        }
        return isValid ? value : nil
    }

    /// `value` trimmed when it is a usable app label: not empty, at most 100 characters, and
    /// without control characters. Otherwise `nil`.
    static func validatedAppName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxAppNameLength,
            !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }
}

/// Picks the mode for a phone request. It never looks at the Mac's active mode (the frontmost
/// app, website or a manual selection on the Mac): the phone's context decides.
enum PhoneModeResolver {
    /// Whether `mode` has an Android app rule matching `app`.
    typealias AndroidAppRuleMatcher = (_ mode: ModeConfig, _ app: String) -> Bool

    /// Matches the Android app rules saved with the mode (`ModeConfig.androidAppConfigs`).
    static let androidAppRules: AndroidAppRuleMatcher = { mode, app in mode.hasAndroidAppRule(for: app) }

    /// The first enabled mode, in configuration order, whose Android app rule matches `app`,
    /// otherwise the enabled Default mode, otherwise the first enabled mode (the Mac's own fallback
    /// when no Default exists).
    static func mode(
        forApp app: String?,
        configurations: [ModeConfig],
        matchesAndroidApp: AndroidAppRuleMatcher = androidAppRules
    ) -> ModeConfig? {
        let enabled = configurations.filter(\.isEnabled)
        if let app, let match = enabled.first(where: { matchesAndroidApp($0, app) }) {
            return match
        }
        return enabled.first(where: \.isDefault) ?? enabled.first
    }
}

/// A readable name for an Android package, without network access: a few well-known apps get
/// their usual name, every other package is shown as is.
enum AndroidAppName {
    private static let knownApps: [String: String] = [
        "com.whatsapp": "WhatsApp",
        "com.whatsapp.w4b": "WhatsApp Business",
        "org.telegram.messenger": "Telegram",
        "org.thoughtcrime.securesms": "Signal",
        "com.google.android.gm": "Gmail",
        "com.google.android.apps.messaging": "Messages",
        "com.google.android.keep": "Keep",
        "com.google.android.apps.docs.editors.docs": "Google Docs",
        "com.google.android.googlequicksearchbox": "Google",
        "com.android.chrome": "Chrome",
        "org.mozilla.firefox": "Firefox",
        "com.microsoft.office.outlook": "Outlook",
        "com.microsoft.teams": "Teams",
        "com.slack": "Slack",
        "com.discord": "Discord",
        "com.facebook.orca": "Messenger",
        "com.instagram.android": "Instagram",
        "com.twitter.android": "X",
        "com.linkedin.android": "LinkedIn",
        "com.samsung.android.messaging": "Samsung Messages",
        "com.android.mms": "Messages",
        "notion.id": "Notion",
        "md.obsidian": "Obsidian",
    ]

    static func displayName(for package: String) -> String {
        knownApps[package] ?? package
    }
}
