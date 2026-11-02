//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
@testable import VoiceInk

@MainActor
struct VoiceInkTests {

    private struct CaptureResult {
        var clipboardReads = 0
        var screenCaptureStarts = 0
        var screenCaptureLanguage: String?
        var tasks: [Task<Void, Never>] = []
        var snapshot = RecordingContextSnapshot()
    }

    private func configuration(
        isEnabled: Bool = true,
        clipboard: Bool = false,
        selectedText: Bool = false,
        screen: Bool = false
    ) -> EnhancementRuntimeConfiguration {
        EnhancementRuntimeConfiguration(
            mode: nil,
            isEnabled: isEnabled,
            prompt: nil,
            provider: .groq,
            modelName: "openai/gpt-oss-120b",
            useClipboardContext: clipboard,
            useSelectedTextContext: selectedText,
            useScreenCaptureContext: screen
        )
    }

    private func capture(with configuration: EnhancementRuntimeConfiguration?) -> CaptureResult {
        var result = CaptureResult()
        let store = RecordingContextSnapshotStore(savedVocabulary: RecordingVocabulary())
        result.tasks = RecordingContextCaptureGate(configuration: configuration).startCapture(
            into: store,
            language: "en",
            readClipboard: {
                result.clipboardReads += 1
                return "copied text"
            },
            startScreenCapture: { _, language in
                result.screenCaptureStarts += 1
                result.screenCaptureLanguage = language
                return [Task {}]
            }
        )
        result.snapshot = store.snapshot
        return result
    }

    @Test
    func disabledEnhancementStartsNoContextCapture() {
        let result = capture(
            with: configuration(isEnabled: false, clipboard: true, selectedText: true, screen: true)
        )

        #expect(result.clipboardReads == 0)
        #expect(result.screenCaptureStarts == 0)
        #expect(result.tasks.isEmpty)
        #expect(result.snapshot.clipboardText == nil)
    }

    @Test
    func missingEnhancementConfigurationStartsNoContextCapture() {
        let result = capture(with: nil)

        #expect(result.clipboardReads == 0)
        #expect(result.screenCaptureStarts == 0)
        #expect(result.tasks.isEmpty)
    }

    @Test
    func clipboardOnlyReadsClipboardWithoutScreenCapture() {
        let result = capture(with: configuration(clipboard: true))

        #expect(result.clipboardReads == 1)
        #expect(result.snapshot.clipboardText == "copied text")
        #expect(result.screenCaptureStarts == 0)
        #expect(result.tasks.isEmpty)
    }

    @Test
    func screenOnlyStartsScreenCaptureWithoutReadingClipboard() {
        let result = capture(with: configuration(screen: true))

        #expect(result.clipboardReads == 0)
        #expect(result.snapshot.clipboardText == nil)
        #expect(result.screenCaptureStarts == 1)
        #expect(result.screenCaptureLanguage == "en")
        #expect(result.tasks.count == 1)
    }

    @Test
    func selectedTextOnlyStartsNoRecordingStartCapture() {
        let result = capture(with: configuration(selectedText: true))

        #expect(result.clipboardReads == 0)
        #expect(result.screenCaptureStarts == 0)
        #expect(result.tasks.isEmpty)
    }

    @Test
    func selectedTextFetchIsSkippedWhenDisabled() async {
        #expect(await SelectedTextService.fetchSelectedText(isEnabled: false) == nil)
    }

    @Test
    func allSourcesCaptureClipboardAndScreen() {
        let result = capture(with: configuration(clipboard: true, selectedText: true, screen: true))

        #expect(result.clipboardReads == 1)
        #expect(result.snapshot.clipboardText == "copied text")
        #expect(result.screenCaptureStarts == 1)
        #expect(result.tasks.count == 1)
    }
}
