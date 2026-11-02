import Foundation

/// Fork-only privacy gate for recording-start context capture.
///
/// Upstream snapshots the clipboard and starts screen capture for every recording,
/// then lets the final mode decide whether to use them. The fork reads neither unless
/// the mode resolved at recording start enables AI enhancement and that context
/// source. Selected text is already gated upstream at enhancement time through
/// `SelectedTextService.fetchSelectedText(isEnabled:)`.
///
/// Kept in its own file so upstream edits to `RecordingContextSnapshot.swift` and
/// `VoiceInkEngine.swift` merge without touching fork logic.
struct RecordingContextCaptureGate: Equatable {
    let capturesClipboard: Bool
    let capturesScreen: Bool

    init(configuration: EnhancementRuntimeConfiguration?) {
        let isEnabled = configuration?.isEnabled == true
        capturesClipboard = isEnabled && configuration?.useClipboardContext == true
        capturesScreen = isEnabled && configuration?.useScreenCaptureContext == true
    }

    @MainActor
    static func forCurrentMode(enhancementService: AIEnhancementService?) -> Self {
        guard let enhancementService, let aiService = enhancementService.getAIService() else {
            return Self(configuration: nil)
        }
        return Self(
            configuration: ModeRuntimeResolver.currentEnhancementConfiguration(
                enhancementService: enhancementService,
                aiService: aiService
            )
        )
    }

    /// Gated entry point to `RecordingContextCaptureService.startCapture(into:language:)`.
    /// The readers are injectable so tests never touch the clipboard or the screen.
    @MainActor
    func startCapture(
        into store: RecordingContextSnapshotStore,
        language: String?,
        readClipboard: @MainActor () -> String? = { SelectedTextService.captureClipboardText() },
        startScreenCapture: @MainActor (RecordingContextSnapshotStore, String?) -> [Task<Void, Never>] = {
            RecordingContextCaptureService.startCapture(into: $0, language: $1)
        }
    ) -> [Task<Void, Never>] {
        if capturesClipboard {
            store.updateClipboardText(readClipboard())
        }
        return capturesScreen ? startScreenCapture(store, language) : []
    }
}
