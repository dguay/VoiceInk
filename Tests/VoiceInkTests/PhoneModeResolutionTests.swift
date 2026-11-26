import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import VoiceInk

// Issue #53: the phone, not the Mac's last mode, decides how a phone dictation is processed.

// MARK: - Mode resolution

struct PhoneModeResolverTests {
    private let development = ModeConfig(name: "Development", isAIEnhancementEnabled: true)
    private let raw = ModeConfig(name: "Raw", isAIEnhancementEnabled: false)
    private let defaultMode = ModeConfig(name: "Default", isAIEnhancementEnabled: true, isDefault: true)

    @Test func noAppUsesTheDefaultModeEvenWhenAnotherModeComesFirst() {
        let resolved = PhoneModeResolver.mode(forApp: nil, configurations: [development, raw, defaultMode])
        #expect(resolved?.id == defaultMode.id)
    }

    @Test func anUnmappedAppUsesTheDefaultMode() {
        let resolved = PhoneModeResolver.mode(forApp: "com.whatsapp", configurations: [development, defaultMode])
        #expect(resolved?.id == defaultMode.id)
    }

    @Test func aModeWithAMatchingAndroidAppRuleWins() {
        let configurations = [defaultMode, raw, development]
        let matcher: PhoneModeResolver.AndroidAppRuleMatcher = { mode, app in
            mode.id == development.id && app == "com.slack"
        }
        #expect(
            PhoneModeResolver.mode(forApp: "com.slack", configurations: configurations, matchesAndroidApp: matcher)?.id
                == development.id)
        #expect(
            PhoneModeResolver.mode(forApp: "com.whatsapp", configurations: configurations, matchesAndroidApp: matcher)?
                .id == defaultMode.id)
        // Without an app, no rule can match.
        #expect(
            PhoneModeResolver.mode(forApp: nil, configurations: configurations, matchesAndroidApp: { _, _ in true })?.id
                == defaultMode.id)
    }

    @Test func aDisabledModeNeverMatches() {
        var disabled = development
        disabled.isEnabled = false
        let resolved = PhoneModeResolver.mode(
            forApp: "com.slack", configurations: [disabled, defaultMode], matchesAndroidApp: { _, _ in true })
        #expect(resolved?.id == defaultMode.id)
    }

    @Test func withoutAnEnabledDefaultTheFirstEnabledModeApplies() {
        var disabledDefault = defaultMode
        disabledDefault.isEnabled = false
        var disabledDevelopment = development
        disabledDevelopment.isEnabled = false
        let resolved = PhoneModeResolver.mode(
            forApp: nil, configurations: [disabledDevelopment, disabledDefault, raw])
        #expect(resolved?.id == raw.id)

        #expect(PhoneModeResolver.mode(forApp: nil, configurations: [disabledDevelopment, disabledDefault]) == nil)
        #expect(PhoneModeResolver.mode(forApp: nil, configurations: []) == nil)
    }

    @Test func theDefaultMatcherReadsTheModesAndroidAppRules() {
        var slack = development
        slack.androidAppConfigs = [AndroidAppConfig(packageName: "com.slack")]
        #expect(PhoneModeResolver.androidAppRules(slack, "com.slack"))
        #expect(PhoneModeResolver.androidAppRules(slack, "com.whatsapp") == false)
        #expect(PhoneModeResolver.androidAppRules(development, "com.slack") == false)
    }
}

// MARK: - Request parsing

struct PhoneDictationRequestContextTests {
    @Test func absentParametersAreNil() {
        let context = PhoneDictationRequestContext(query: [:])
        #expect(context == .empty)
        #expect(context.skipsAIEnhancementAndFormatting == false)
    }

    @Test func fieldKindsAreParsedCaseInsensitivelyAndUnknownIsOther() {
        let cases: [String: PhoneDictationFieldKind] = [
            "text": .text, "email": .email, "URL": .url, "Number": .number, "other": .other,
            "password": .other, "": .other,
        ]
        for (value, expected) in cases {
            #expect(PhoneDictationRequestContext(query: ["field": value]).field == expected, "field=\(value)")
        }
    }

    @Test func onlyEmailURLAndNumberFieldsSkipCleanup() {
        for kind in PhoneDictationFieldKind.allCases {
            let expected = kind == .email || kind == .url || kind == .number
            #expect(PhoneDictationRequestContext(app: nil, field: kind).skipsAIEnhancementAndFormatting == expected)
        }
    }

    @Test func plausiblePackageNamesAreKept() {
        for app in ["com.whatsapp", "org.telegram.messenger", "com.google.android.gm", "android", "a.b_c.D1"] {
            #expect(PhoneDictationRequestContext(query: ["app": app]).app == app, "app=\(app)")
        }
    }

    @Test func malformedPackageNamesAreIgnored() {
        let tooLong = "com." + String(repeating: "a", count: PhoneDictationRequestContext.maxAppLength)
        for app in ["", " ", "com..whatsapp", ".com", "com.", "1com.app", "com.1app", "com.what sapp", "com/whatsapp",
            "com.wh\u{e4}tsapp", "com.app;drop", tooLong]
        {
            #expect(PhoneDictationRequestContext(query: ["app": app]).app == nil, "app=\(app)")
        }
        let longest = String(repeating: "a", count: PhoneDictationRequestContext.maxAppLength)
        #expect(PhoneDictationRequestContext(query: ["app": longest]).app == longest)
    }

    @Test func queryParametersAreReadFromTheRequestLine() throws {
        let head = try #require(
            PhoneDictationHTTPRequestHead.parse(
                Data("POST /v1/transcribe?format=m4a&app=com.google.android.gm&field=email HTTP/1.1\r\n".utf8)))
        #expect(
            PhoneDictationRequestContext(query: head.query)
                == PhoneDictationRequestContext(app: "com.google.android.gm", field: .email))
    }

    @Test func theControllerTurnsTheContextIntoPipelineOptions() {
        let email = PhoneDictationController.transcriptionOptions(
            for: PhoneDictationRequestContext(app: "com.google.android.gm", field: .email))
        #expect(email == AudioFileTranscriptionOptions(sourceApp: "com.google.android.gm", skipsAIEnhancementAndFormatting: true))

        let text = PhoneDictationController.transcriptionOptions(
            for: PhoneDictationRequestContext(app: "com.whatsapp", field: .text))
        #expect(text == AudioFileTranscriptionOptions(sourceApp: "com.whatsapp", skipsAIEnhancementAndFormatting: false))

        #expect(PhoneDictationController.transcriptionOptions(for: .empty) == AudioFileTranscriptionOptions())
    }

    @Test func wellKnownAppsGetAFriendlyNameAndOthersKeepThePackage() {
        #expect(AndroidAppName.displayName(for: "com.whatsapp") == "WhatsApp")
        #expect(AndroidAppName.displayName(for: "com.example.notes") == "com.example.notes")
    }
}

// MARK: - Server: the context reaches the handler

private final class ContextTokenStorage: PhoneDictationTokenStorage {
    var token: String?
    func readToken() -> String? { token }
    func writeToken(_ token: String) -> Bool {
        self.token = token
        return true
    }
}

@MainActor
private final class ContextProbe {
    var contexts: [PhoneDictationRequestContext] = []
}

@MainActor
@Suite(.serialized)
struct PhoneDictationServerContextTests {
    private func post(_ path: String, port: UInt16, token: String) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data([1, 2, 3, 4])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        return (response as! HTTPURLResponse).statusCode
    }

    @Test func appAndFieldReachTheTranscribeHandler() async throws {
        let tokenStore = PhoneDictationTokenStore(storage: ContextTokenStorage())
        let token = try tokenStore.currentToken()
        let probe = ContextProbe()
        let server = PhoneDictationServer(
            tokenStore: tokenStore,
            handlers: PhoneDictationHandlers(
                readiness: { .ready(model: "Fake Model", mode: "Default") },
                transcribe: { _, context in
                    probe.contexts.append(context)
                    return PhoneDictationTranscribeBody(
                        id: UUID(), text: "ok", durationSeconds: 1, model: "Fake Model", mode: "Default",
                        enhancementError: nil)
                }
            ),
            maxBodyBytes: 4096
        )
        let port = try await server.start(port: 0)
        defer { server.stop() }

        #expect(try await post("/v1/transcribe?app=com.google.android.gm&field=email", port: port, token: token) == 200)
        #expect(try await post("/v1/transcribe", port: port, token: token) == 200)
        #expect(try await post("/v1/transcribe?app=not%20a%20package&field=fancy", port: port, token: token) == 200)

        #expect(
            probe.contexts == [
                PhoneDictationRequestContext(app: "com.google.android.gm", field: .email),
                .empty,
                PhoneDictationRequestContext(app: nil, field: .other),
            ])
    }
}

// MARK: - Pipeline: no cleanup for email, URL and number fields

@MainActor
private final class EchoTranscriber: AudioFileTranscriber {
    let output: String
    init(output: String) { self.output = output }
    func transcribe(
        audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> String { output }
    func cleanup() async {}
}

private struct ContextFakeModel: TranscriptionModel {
    let id = UUID()
    let name = "fake-model"
    let displayName = "Fake Model"
    let description = "Test model"
    let provider: ModelProvider = .groq
    let isMultilingualModel = false
    let supportedLanguages: [String: String] = ["en": "English"]
}

@MainActor
@Suite(.serialized)
struct PhoneFieldKindPipelineTests {
    /// Long enough that paragraph formatting splits it.
    private let spoken = Array(
        repeating: "This sentence has quite a few words in it for the formatter to count.", count: 10
    ).joined(separator: " ")

    private func run(options: AudioFileTranscriptionOptions) async throws -> (AudioFileTranscriptionResult, ModelContext) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneModeResolutionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let container = try ModelContainer(
            for: Transcription.self, VocabularyWord.self, WordReplacement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let spoken = self.spoken
        context.insert(WordReplacement(originalText: "quite", replacementText: "QUITE"))
        try context.save()

        let pipeline = AudioFileTranscriptionPipeline(
            modelContext: context,
            dependencies: .init(
                resolveConfiguration: { mode in
                    TranscriptionRuntimeConfiguration(
                        mode: mode, model: ContextFakeModel(), language: "en", isRealtimeEnabled: false)
                },
                makeTranscriber: { EchoTranscriber(output: spoken) },
                enhancementService: nil,
                recordingsDirectory: directory.appendingPathComponent("Recordings")
            )
        )
        let mode = ModeConfig(
            name: "Default", isAIEnhancementEnabled: true, isTextFormattingEnabled: true, isDefault: true)
        let result = try await pipeline.transcribe(
            audioURL: try writeTone(in: directory), mode: mode, source: .phone, options: options)
        return (result, context)
    }

    private func writeTone(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("recording.m4a")
        let sampleRate = 44_100.0
        let file = try AVAudioFile(
            forWriting: url,
            settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 22_050))
        buffer.frameLength = 22_050
        let channel = try #require(buffer.floatChannelData?[0])
        for frame in 0..<22_050 {
            channel[frame] = Float(sin(2 * .pi * 440 * Double(frame) / sampleRate)) * 0.3
        }
        try file.write(from: buffer)
        return url
    }

    @Test func skippingCleanupKeepsReplacementsButNotFormatting() async throws {
        let (result, context) = try await run(
            options: AudioFileTranscriptionOptions(sourceApp: "com.google.android.gm", skipsAIEnhancementAndFormatting: true))
        let expected = spoken.replacingOccurrences(of: "quite", with: "QUITE")
        #expect(result.finalText == expected)
        #expect(result.enhancementFailure == nil)

        let entry = try #require(try context.fetch(FetchDescriptor<Transcription>()).first)
        #expect(entry.text == expected)
        #expect(entry.enhancedText == nil)
        #expect(entry.sourceApp == "com.google.android.gm")
        #expect(entry.transcriptionSource == .phone)
        #expect(entry.modeName == "Default")
    }

    @Test func plainTextFieldsStillGetTheModesFormatting() async throws {
        let (result, context) = try await run(options: AudioFileTranscriptionOptions(sourceApp: "com.whatsapp"))
        #expect(result.finalText.contains("\n"))
        #expect(result.finalText.contains("QUITE"))
        let entry = try #require(try context.fetch(FetchDescriptor<Transcription>()).first)
        #expect(entry.sourceApp == "com.whatsapp")
    }

    @Test func entriesWithoutAnAppKeepNoSourceApp() async throws {
        let (_, context) = try await run(options: AudioFileTranscriptionOptions())
        let entry = try #require(try context.fetch(FetchDescriptor<Transcription>()).first)
        #expect(entry.sourceApp == nil)
    }
}
