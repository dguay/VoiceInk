//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
@testable import VoiceInk

struct VoiceInkTests {

    @Test @MainActor
    func disabledEnhancementStartsNoContextCapture() {
        let configuration = EnhancementRuntimeConfiguration(
            mode: nil,
            isEnabled: false,
            prompt: nil,
            provider: .groq,
            modelName: "openai/gpt-oss-120b",
            useClipboardContext: true,
            useSelectedTextContext: true,
            useScreenCaptureContext: true
        )
        let plan = RecordingContextCapturePlan(configuration: configuration)
        let store = RecordingContextSnapshotStore()

        #expect(plan.sources.isEmpty)
        #expect(RecordingContextCaptureService.startCapture(into: store, plan: plan).isEmpty)
    }

    @Test
    func enhancedModeCapturesOnlyEnabledContextSources() {
        let configuration = EnhancementRuntimeConfiguration(
            mode: nil,
            isEnabled: true,
            prompt: nil,
            provider: .groq,
            modelName: "openai/gpt-oss-120b",
            useClipboardContext: false,
            useSelectedTextContext: true,
            useScreenCaptureContext: true
        )

        let plan = RecordingContextCapturePlan(configuration: configuration)

        #expect(plan.sources == [.selectedText, .screen])
    }

}
