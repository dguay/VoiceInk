import AppKit
import SwiftUI

/// Never becomes key, so the user's field keeps keyboard focus and Paste goes to it.
@MainActor
private final class PasteRecoveryPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A finished transcript that was not delivered automatically.
struct PasteRecoveryCard: Equatable, Identifiable {
    let id: UUID
    let text: String
    let reason: PasteRecoveryReason
}

/// Floating card offering Paste, Copy and Dismiss for a transcript that was held back
/// or failed to land. History is unaffected: the card only holds a copy of the text.
@MainActor
final class PasteRecoveryCardController: ObservableObject, PasteRecoveryPresenting {
    static let shared = PasteRecoveryCardController()

    @Published private(set) var card: PasteRecoveryCard?

    private let presentsPanel: Bool
    private let pasteText: @MainActor (String) -> Void
    private let copyText: @MainActor (String) -> Bool
    private var panel: NSPanel?

    init(
        presentsPanel: Bool = true,
        pasteText: @escaping @MainActor (String) -> Void = { CursorPaster.pasteAtCursor($0) },
        copyText: @escaping @MainActor (String) -> Bool = { ClipboardManager.copyToClipboard($0) }
    ) {
        self.presentsPanel = presentsPanel
        self.pasteText = pasteText
        self.copyText = copyText
    }

    func present(text: String, reason: PasteRecoveryReason) {
        card = PasteRecoveryCard(id: UUID(), text: text, reason: reason)
        guard presentsPanel else { return }
        if panel == nil { makePanel() }
        resizePanel()
        // Show without activating VoiceInk or taking keyboard focus.
        panel?.orderFrontRegardless()
    }

    /// Pastes into whatever field is focused now, then closes the card.
    func paste() {
        guard let card else { return }
        close()
        pasteText(card.text)
    }

    /// Copies the transcript to the clipboard, then closes the card.
    func copy() {
        guard let card else { return }
        _ = copyText(card.text)
        close()
    }

    func dismiss() {
        close()
    }

    private func close() {
        card = nil
        panel?.orderOut(nil)
    }

    private func makePanel() {
        let hostingView = PasteRecoveryHostingView(rootView: PasteRecoveryCardHost(controller: self))
        let size = hostingView.fittingSize
        let frame = Self.frame(for: size, screen: nil) ?? NSRect(origin: .zero, size: size)
        let panel = PasteRecoveryPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
    }

    private func resizePanel() {
        guard let panel, let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        if let frame = Self.frame(for: size, screen: panel.screen) {
            panel.setFrame(frame, display: true)
        } else {
            panel.setContentSize(size)
        }
    }

    private static func frame(for size: NSSize, screen: NSScreen?) -> NSRect? {
        MiniRecorderPanel.calculateWindowMetrics(size: size, screen: screen)?.offsetBy(dx: 0, dy: 48)
    }
}

private struct PasteRecoveryCardHost: View {
    @ObservedObject var controller: PasteRecoveryCardController

    var body: some View {
        if let card = controller.card {
            PasteRecoveryCardView(
                text: card.text,
                message: card.reason.message,
                onPaste: controller.paste,
                onCopy: controller.copy,
                onDismiss: controller.dismiss
            )
        }
    }
}

extension PasteRecoveryReason {
    var message: String {
        switch self {
        case .heldBack(.applicationChanged), .heldBack(.windowChanged), .heldBack(.fieldChanged):
            return String(localized: "Focus moved while VoiceInk was processing, so the text was not pasted.")
        case .heldBack(.secureField):
            return String(localized: "A password field is focused, so the text was not pasted.")
        case .heldBack(.notEditable):
            return String(localized: "The focused item does not accept text, so the text was not pasted.")
        case .notPosted:
            return String(localized: "VoiceInk could not paste the text.")
        case .partiallyPosted:
            return String(localized: "Pasting was interrupted. Check the destination before pasting again.")
        case .notLanded:
            return String(localized: "The text does not appear in the focused field.")
        }
    }
}

struct PasteRecoveryCardView: View {
    let text: String
    let message: String
    let onPaste: () -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcript not pasted")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .vertical) {
                transcript
                ScrollView {
                    transcript
                }
                .frame(height: 120)
            }
            .frame(maxHeight: 120, alignment: .topLeading)

            HStack(spacing: 8) {
                Spacer(minLength: 12)
                Button(action: onDismiss) {
                    Text("Dismiss").frame(minWidth: 60)
                }
                .buttonStyle(.bordered)
                Button(action: onCopy) {
                    Text("Copy").frame(minWidth: 60)
                }
                .buttonStyle(.bordered)
                Button(action: onPaste) {
                    Text("Paste").frame(minWidth: 60)
                }
                .buttonStyle(.borderedProminent)
                .environment(\.controlActiveState, .key)
            }
            .font(.system(size: 13, weight: .medium))
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
        }
        .padding(16)
        .frame(width: 400)
        .background {
            PasteRecoveryBackdrop()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .allowsHitTesting(false)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var transcript: some View {
        Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PasteRecoveryBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Takes the first click, since the panel never becomes key.
private final class PasteRecoveryHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
