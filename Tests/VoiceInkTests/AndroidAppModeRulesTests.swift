import Foundation
import Testing
@testable import VoiceInk

// Issue #57: modes can apply to Android apps, for phone dictations.

// MARK: - Resolution precedence

struct AndroidAppModeResolutionTests {
    private func mode(
        _ name: String, androidApps: [String] = [], isEnabled: Bool = true, isDefault: Bool = false
    ) -> ModeConfig {
        ModeConfig(
            name: name,
            androidAppConfigs: androidApps.isEmpty ? nil : androidApps.map { AndroidAppConfig(packageName: $0) },
            isAIEnhancementEnabled: false, isEnabled: isEnabled, isDefault: isDefault)
    }

    @Test func aMappedAppUsesItsMode() {
        let defaultMode = mode("Default", isDefault: true)
        let chat = mode("Chat", androidApps: ["com.whatsapp", "org.telegram.messenger"])
        let configurations = [defaultMode, chat]
        #expect(PhoneModeResolver.mode(forApp: "com.whatsapp", configurations: configurations)?.id == chat.id)
        #expect(PhoneModeResolver.mode(forApp: "org.telegram.messenger", configurations: configurations)?.id == chat.id)
    }

    @Test func anAppMappedInTwoModesUsesTheFirstInConfigurationOrder() {
        let defaultMode = mode("Default", isDefault: true)
        let first = mode("First", androidApps: ["com.slack"])
        let second = mode("Second", androidApps: ["com.slack"])
        #expect(
            PhoneModeResolver.mode(forApp: "com.slack", configurations: [defaultMode, first, second])?.id == first.id)
        #expect(
            PhoneModeResolver.mode(forApp: "com.slack", configurations: [second, defaultMode, first])?.id == second.id)
    }

    @Test func anUnmappedAppUsesTheDefaultMode() {
        let chat = mode("Chat", androidApps: ["com.whatsapp"])
        let defaultMode = mode("Default", isDefault: true)
        #expect(
            PhoneModeResolver.mode(forApp: "com.google.android.gm", configurations: [chat, defaultMode])?.id
                == defaultMode.id)
    }

    @Test func aDisabledModeThatMapsTheAppIsSkipped() {
        let disabled = mode("Disabled", androidApps: ["com.slack"], isEnabled: false)
        let enabled = mode("Enabled", androidApps: ["com.slack"])
        let defaultMode = mode("Default", isDefault: true)
        #expect(PhoneModeResolver.mode(forApp: "com.slack", configurations: [disabled, defaultMode])?.id == defaultMode.id)
        #expect(
            PhoneModeResolver.mode(forApp: "com.slack", configurations: [disabled, defaultMode, enabled])?.id
                == enabled.id)
    }

    @Test func aRequestWithoutAnAppUsesTheDefaultMode() {
        let chat = mode("Chat", androidApps: ["com.whatsapp"])
        let defaultMode = mode("Default", isDefault: true)
        #expect(PhoneModeResolver.mode(forApp: nil, configurations: [chat, defaultMode])?.id == defaultMode.id)
    }

    @Test func removingTheMappingReturnsTheAppToTheDefaultMode() {
        var chat = mode("Chat", androidApps: ["com.whatsapp"])
        let defaultMode = mode("Default", isDefault: true)
        #expect(PhoneModeResolver.mode(forApp: "com.whatsapp", configurations: [chat, defaultMode])?.id == chat.id)

        var rules = chat.androidAppConfigs ?? []
        rules.removeRule(for: "com.whatsapp")
        chat.androidAppConfigs = rules.isEmpty ? nil : rules
        #expect(
            PhoneModeResolver.mode(forApp: "com.whatsapp", configurations: [chat, defaultMode])?.id == defaultMode.id)
    }

    @Test func macAppRulesDoNotMatchPhoneRequests() {
        // A Mac bundle ID that looks like a package name is not an Android app rule.
        let mac = ModeConfig(
            name: "Mac", appConfigs: [AppConfig(bundleIdentifier: "com.tinyspeck.slackmacgap", appName: "Slack")],
            isAIEnhancementEnabled: false)
        let defaultMode = mode("Default", isDefault: true)
        #expect(
            PhoneModeResolver.mode(forApp: "com.tinyspeck.slackmacgap", configurations: [mac, defaultMode])?.id
                == defaultMode.id)
    }
}

// MARK: - Saved settings

struct AndroidAppModeSettingsTests {
    /// A mode as saved before Android app rules existed.
    private let legacyModeJSON = """
        {"id":"6B1C6B8E-1D7A-4C2E-9F55-2E3B9E1C0A11","name":"Writing","icon":{"kind":"symbol","value":"pencil"},
        "appConfigs":[{"id":"0F5C1B9A-3F43-4C1F-8E5D-4B8B6E0F8C21","bundleIdentifier":"com.apple.TextEdit","appName":"TextEdit"}],
        "urlConfigs":[{"id":"7A2D9C4E-5B6F-4E1A-9C3B-8D7E6F5A4B31","url":"docs.google.com"}],
        "isAIEnhancementEnabled":true,"isRealtimeTranscriptionEnabled":true,"selectedLanguage":"en",
        "isTextFormattingEnabled":true,"useClipboardContext":false,"useSelectedTextContext":true,
        "useScreenCapture":false,"outputMode":"paste","autoSendKey":"none","isEnabled":true,"isDefault":false}
        """

    @Test func modesSavedBeforeAndroidAppRulesDecodeUnchanged() throws {
        let mode = try JSONDecoder().decode(ModeConfig.self, from: Data(legacyModeJSON.utf8))
        #expect(mode.name == "Writing")
        #expect(mode.androidAppConfigs == nil)
        #expect(mode.appConfigs?.map(\.bundleIdentifier) == ["com.apple.TextEdit"])
        #expect(mode.urlConfigs?.map(\.url) == ["docs.google.com"])
        #expect(mode.isAIEnhancementEnabled)
        #expect(mode.isTextFormattingEnabled)

        // Saving it again does not invent an empty rule list.
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mode)) as? [String: Any]
        #expect(reencoded?["androidAppConfigs"] == nil)
    }

    @Test func androidAppRulesAreSavedWithTheMode() throws {
        let rules = [
            AndroidAppConfig(packageName: "com.whatsapp", appName: "WhatsApp"),
            AndroidAppConfig(packageName: "com.example.notes"),
        ]
        let mode = ModeConfig(name: "Chat", androidAppConfigs: rules, isAIEnhancementEnabled: false)
        let decoded = try JSONDecoder().decode(ModeConfig.self, from: JSONEncoder().encode(mode))
        #expect(decoded.androidAppConfigs?.map(\.packageName) == ["com.whatsapp", "com.example.notes"])
        #expect(decoded.androidAppConfigs?.map(\.appName) == ["WhatsApp", nil])
        #expect(decoded.androidAppConfigs?.map(\.id) == rules.map(\.id))
    }

    @Test func backupExportAndImportRoundTripTheRules() throws {
        let chat = ModeConfig(
            name: "Chat",
            androidAppConfigs: [AndroidAppConfig(packageName: "org.telegram.messenger", appName: "Telegram")],
            isAIEnhancementEnabled: false)
        let defaultMode = ModeConfig(name: "Default", isAIEnhancementEnabled: false, isDefault: true)
        let backup = BackupFile(
            version: "1.0", customPrompts: [], modeConfigs: [chat, defaultMode], modeShortcuts: nil,
            vocabularyWords: nil, wordReplacements: nil, generalSettings: nil, customEmojis: nil,
            customCloudModels: nil)

        let restored = try JSONDecoder().decode(BackupFile.self, from: JSONEncoder().encode(backup))
        #expect(restored.modeConfigs.map(\.id) == [chat.id, defaultMode.id])
        let rules = try #require(restored.modeConfigs.first?.androidAppConfigs)
        #expect(rules.map(\.packageName) == ["org.telegram.messenger"])
        #expect(rules.map(\.appName) == ["Telegram"])
        #expect(restored.modeConfigs.last?.androidAppConfigs == nil)
        #expect(
            PhoneModeResolver.mode(forApp: "org.telegram.messenger", configurations: restored.modeConfigs)?.id
                == chat.id)
    }

    @Test func anOlderBackupWithoutRulesStillImports() throws {
        let json = """
            {"version":"1.40","customPrompts":[],"modeConfigs":[\(legacyModeJSON)]}
            """
        let backup = try JSONDecoder().decode(BackupFile.self, from: Data(json.utf8))
        #expect(backup.modeConfigs.map(\.name) == ["Writing"])
        #expect(backup.modeConfigs.first?.androidAppConfigs == nil)
    }
}

// MARK: - Editing rules

struct AndroidAppRuleEditingTests {
    @Test func typedPackageNamesAreValidatedLikeTheAppParameter() {
        var rules: [AndroidAppConfig] = []
        let added = rules.addRule(packageName: "  com.whatsapp  ")
        #expect(added)
        #expect(rules.map(\.packageName) == ["com.whatsapp"])
        for invalid in ["", "com..app", "1com.app", "com.what sapp", "com/whatsapp", "WhatsApp Messenger"] {
            let addedInvalid = rules.addRule(packageName: invalid)
            #expect(addedInvalid == false, "package=\(invalid)")
        }
        #expect(rules.count == 1)
    }

    @Test func anAppIsAddedOnceAndCanBeRemoved() {
        var rules: [AndroidAppConfig] = []
        let addedFirst = rules.addRule(packageName: "com.slack", appName: "Slack")
        #expect(addedFirst)
        let addedAgain = rules.addRule(packageName: "com.slack")
        #expect(addedAgain == false)
        #expect(rules.first?.displayName == "Slack")
        rules.removeRule(for: "com.slack")
        #expect(rules.isEmpty)
    }

    @Test func theDisplayNamePrefersThePhonesLabel() {
        #expect(AndroidAppConfig(packageName: "com.whatsapp", appName: "WA").displayName == "WA")
        #expect(AndroidAppConfig(packageName: "com.whatsapp").displayName == "WhatsApp")
        #expect(AndroidAppConfig(packageName: "com.example.notes").displayName == "com.example.notes")
    }
}

// MARK: - Readable app name on the request

struct PhoneDictationAppNameTests {
    @Test func theReadableNameIsReadWithAValidApp() {
        let context = PhoneDictationRequestContext(query: ["app": "com.whatsapp", "appName": "  WhatsApp  "])
        #expect(context.app == "com.whatsapp")
        #expect(context.appName == "WhatsApp")
    }

    @Test func anUnusableOrOrphanNameIsIgnored() {
        let tooLong = String(repeating: "a", count: PhoneDictationRequestContext.maxAppNameLength + 1)
        for name in ["", "   ", tooLong, "Bad\u{0}Name", "Two\nLines"] {
            let context = PhoneDictationRequestContext(query: ["app": "com.whatsapp", "appName": name])
            #expect(context.appName == nil, "appName=\(name.debugDescription)")
            #expect(context.app == "com.whatsapp")
        }
        let longest = String(repeating: "a", count: PhoneDictationRequestContext.maxAppNameLength)
        #expect(PhoneDictationRequestContext(query: ["app": "com.whatsapp", "appName": longest]).appName == longest)
        // Without a valid app, the name has nothing to describe.
        #expect(PhoneDictationRequestContext(query: ["appName": "WhatsApp"]).appName == nil)
        #expect(PhoneDictationRequestContext(query: ["app": "not valid", "appName": "WhatsApp"]).appName == nil)
    }

    @Test func olderPhonesWithoutTheNameKeepWorking() {
        let context = PhoneDictationRequestContext(query: ["app": "com.whatsapp", "field": "text"])
        #expect(context == PhoneDictationRequestContext(app: "com.whatsapp", field: .text))
        #expect(context.appName == nil)
    }

    @Test func theNameIsReadFromAnEncodedRequestLine() throws {
        let head = try #require(
            PhoneDictationHTTPRequestHead.parse(
                Data("POST /v1/transcribe?app=com.google.android.apps.docs.editors.docs&appName=Google%20Docs&field=text HTTP/1.1\r\n".utf8)))
        let context = PhoneDictationRequestContext(query: head.query)
        #expect(context.appName == "Google Docs")
    }
}

// MARK: - Recent Android apps

struct RecentAndroidAppsStoreTests {
    private func makeStore() -> (RecentAndroidAppsStore, UserDefaults) {
        let suite = "RecentAndroidAppsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (RecentAndroidAppsStore(defaults: defaults), defaults)
    }

    @Test func recordsNewestFirstAndKeepsAKnownLabel() {
        let (store, _) = makeStore()
        let start = Date(timeIntervalSince1970: 1_000)
        store.record(packageName: "com.whatsapp", appName: "WhatsApp", at: start)
        store.record(packageName: "com.slack", appName: nil, at: start.addingTimeInterval(1))
        store.record(packageName: "com.whatsapp", appName: nil, at: start.addingTimeInterval(2))
        store.record(packageName: "not a package", appName: "X", at: start.addingTimeInterval(3))

        #expect(store.apps.map(\.packageName) == ["com.whatsapp", "com.slack"])
        #expect(store.apps.first?.appName == "WhatsApp")
        #expect(store.apps.last?.appName == nil)
    }

    @Test func theListIsBounded() {
        let (store, _) = makeStore()
        for index in 0..<(RecentAndroidAppsStore.maxCount + 5) {
            store.record(packageName: "com.example.app\(index)", appName: nil, at: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(store.apps.count == RecentAndroidAppsStore.maxCount)
        #expect(store.apps.first?.packageName == "com.example.app\(RecentAndroidAppsStore.maxCount + 4)")
    }

    @Test func historyPackagesAreMergedWithoutDuplicates() {
        let recorded = [
            RecentAndroidApp(packageName: "com.whatsapp", appName: "WhatsApp", lastSeen: Date(timeIntervalSince1970: 10))
        ]
        let merged = RecentAndroidAppsStore.merged(
            recorded: recorded,
            historyPackages: [
                ("com.whatsapp", Date(timeIntervalSince1970: 20)),
                ("com.slack", Date(timeIntervalSince1970: 15)),
                ("com.slack", Date(timeIntervalSince1970: 5)),
                ("not a package", Date(timeIntervalSince1970: 30)),
            ])
        #expect(merged.map(\.packageName) == ["com.whatsapp", "com.slack"])
        #expect(merged.first?.appName == "WhatsApp")
        #expect(merged.first?.lastSeen == Date(timeIntervalSince1970: 20))
        #expect(merged.last?.displayName == "Slack")
    }
}
