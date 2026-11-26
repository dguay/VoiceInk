import AppKit
import Foundation
import Testing
@testable import VoiceInk

// MARK: - Fakes

private let windowA = PasteFocusIdentity("window-a" as NSString)
private let windowB = PasteFocusIdentity("window-b" as NSString)
private let fieldA = PasteFocusIdentity("field-a" as NSString)
private let fieldB = PasteFocusIdentity("field-b" as NSString)

private func target(
    pid: pid_t = 100,
    bundle: String? = "com.example.editor",
    window: PasteFocusIdentity? = windowA,
    element: PasteFocusElement? = PasteFocusElement(identity: fieldA, role: "AXTextArea", editable: true)
) -> PasteFocusTarget {
    PasteFocusTarget(processID: pid, bundleIdentifier: bundle, window: window, element: element)
}

/// Returns the configured focus. `targets` are consumed one per read; the last one repeats.
private final class FakeFocusReader: PasteFocusReading, @unchecked Sendable {
    var targets: [PasteFocusTarget?]
    var fieldValues: [PasteFieldState?] = []
    private(set) var targetReads = 0
    private(set) var fieldReads = 0

    init(_ targets: PasteFocusTarget?...) {
        self.targets = targets
    }

    private var next: PasteFocusTarget? {
        defer { targetReads += 1 }
        return targets[min(targetReads, targets.count - 1)]
    }

    @MainActor
    func frontmostApplication() -> (processID: pid_t, bundleIdentifier: String?)? {
        guard let current = targets[min(targetReads, targets.count - 1)] else { return nil }
        return (current.processID, current.bundleIdentifier)
    }

    func target(processID: pid_t, bundleIdentifier: String?) async -> PasteFocusTarget {
        next ?? PasteFocusTarget(processID: processID, bundleIdentifier: bundleIdentifier)
    }

    /// What the captured element reports for AXFocused when identities differ.
    var capturedElementFocused: Bool?

    func isFocused(_ element: PasteFocusElement) async -> Bool? {
        capturedElementFocused
    }

    func fieldState(of element: PasteFocusElement) async -> PasteFieldState? {
        defer { fieldReads += 1 }
        guard !fieldValues.isEmpty else { return nil }
        return fieldValues[min(fieldReads, fieldValues.count - 1)]
    }
}

@MainActor
private final class FakePastePerformer: PastePerforming {
    var result: CursorPaster.PasteResult = .commandPosted
    private(set) var pastedTexts: [String] = []
    private(set) var sentKeys: [FinishAndSendKey] = []
    private(set) var commandAttempts = 0

    func paste(
        _ text: String,
        sendKey: FinishAndSendKey,
        beforeCommand: (@MainActor () async -> Bool)?
    ) async -> CursorPaster.PasteOutcome {
        commandAttempts += 1
        if let beforeCommand, !(await beforeCommand()) {
            return CursorPaster.PasteOutcome(result: .heldBack, autoLearnGeneration: nil)
        }
        if result == .commandPosted { pastedTexts.append(text) }
        return CursorPaster.PasteOutcome(result: result, autoLearnGeneration: nil)
    }

    func performSendKey(_ key: FinishAndSendKey, after outcome: CursorPaster.PasteOutcome) async {
        sentKeys.append(key)
    }
}

@MainActor
private final class FakeRecoveryPresenter: PasteRecoveryPresenting {
    private(set) var presented: [(text: String, reason: PasteRecoveryReason)] = []

    func present(text: String, reason: PasteRecoveryReason) {
        presented.append((text, reason))
    }
}

@MainActor
private func makePaster(
    reader: FakeFocusReader,
    performer: FakePastePerformer,
    presenter: FakeRecoveryPresenter,
    guardEnabled: Bool = true
) -> FocusSafePaster {
    FocusSafePaster(
        focusReader: reader,
        performer: performer,
        recovery: presenter,
        isGuardEnabled: { guardEnabled },
        sendKeyDelay: 0,
        verificationInterval: 0.001,
        verificationTimeout: 0.02,
        sleep: { _ in }
    )
}

// MARK: - Target capture

@MainActor
@Suite("Focus-safe paste: target capture")
struct FocusSafePasteCaptureTests {
    @Test func capturesApplicationWindowAndFocusedElement() async {
        let reader = FakeFocusReader(target())
        let paster = makePaster(reader: reader, performer: FakePastePerformer(), presenter: FakeRecoveryPresenter())

        let captured = await paster.captureTarget()?.value

        #expect(captured?.processID == 100)
        #expect(captured?.bundleIdentifier == "com.example.editor")
        #expect(captured?.window == windowA)
        #expect(captured?.element?.identity == fieldA)
        #expect(captured?.element?.editable == true)
    }

    @Test func capturesNothingWhenGuardIsOff() {
        let reader = FakeFocusReader(target())
        let paster = makePaster(
            reader: reader, performer: FakePastePerformer(), presenter: FakeRecoveryPresenter(), guardEnabled: false)

        #expect(paster.captureTarget() == nil)
    }

    @Test func settingDefaultsOnAndPersists() throws {
        let suite = "FocusSafePasteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(PasteFocusGuardSettings.isEnabled(in: defaults))
        defaults.set(false, forKey: PasteFocusGuardSettings.key)
        #expect(!PasteFocusGuardSettings.isEnabled(in: defaults))
    }
}

// MARK: - Focus decisions

@MainActor
@Suite("Focus-safe paste: delivery decisions")
struct FocusSafePasteDecisionTests {
    @Test func unchangedFocusPastesAutomaticallyWithoutCard() async {
        let reader = FakeFocusReader(target())
        reader.fieldValues = [PasteFieldState(value: "Hello"), PasteFieldState(value: "Hello world")]
        let performer = FakePastePerformer()
        let presenter = FakeRecoveryPresenter()
        let paster = makePaster(reader: reader, performer: performer, presenter: presenter)

        let result = await paster.deliver(" world", sendKey: .enter, captured: target())

        #expect(result == .pasted(.landed))
        #expect(performer.pastedTexts == [" world"])
        #expect(performer.sentKeys == [.enter])
        #expect(presenter.presented.isEmpty)
    }

    @Test(arguments: [
        (target(pid: 200, bundle: "com.example.chat"), PasteHoldBackReason.applicationChanged),
        (target(window: windowB), PasteHoldBackReason.windowChanged),
        (target(element: PasteFocusElement(identity: fieldB, role: "AXTextField", editable: true)),
            PasteHoldBackReason.fieldChanged),
    ])
    func focusChangeHoldsBackPasteAndSendKey(current: PasteFocusTarget, reason: PasteHoldBackReason) async {
        let reader = FakeFocusReader(current)
        let performer = FakePastePerformer()
        let presenter = FakeRecoveryPresenter()
        let paster = makePaster(reader: reader, performer: performer, presenter: presenter)

        let result = await paster.deliver("Finished text", sendKey: .enter, captured: target())

        #expect(result == .recovery(.heldBack(reason)))
        #expect(performer.commandAttempts == 0)
        #expect(performer.sentKeys.isEmpty)
        #expect(presenter.presented.map(\.text) == ["Finished text"])
        #expect(presenter.presented.first?.reason == .heldBack(reason))
    }

    @Test func newObjectForStillFocusedFieldIsNotAFocusChange() async {
        // Chromium can hand out a new AX object for the same field once web accessibility turns on.
        let reader = FakeFocusReader(
            target(element: PasteFocusElement(identity: fieldB, role: "AXTextArea", editable: true)))
        reader.capturedElementFocused = true
        let performer = FakePastePerformer()
        let presenter = FakeRecoveryPresenter()
        let paster = makePaster(reader: reader, performer: performer, presenter: presenter)

        let result = await paster.deliver("Text", sendKey: .none, captured: target())

        #expect(result == .pasted(.unverified))
        #expect(performer.pastedTexts == ["Text"])
        #expect(presenter.presented.isEmpty)
    }

    @Test func capturedElementFocusOnlyMattersForFieldChanges() {
        let moved = target(element: PasteFocusElement(identity: fieldB, editable: true))
        #expect(PasteFocusGuard.decide(captured: target(), current: moved, capturedElementStillFocused: false)
            == .holdBack(.fieldChanged))
        #expect(PasteFocusGuard.decide(captured: target(), current: moved, capturedElementStillFocused: nil)
            == .holdBack(.fieldChanged))
        #expect(PasteFocusGuard.decide(captured: target(), current: target(pid: 5), capturedElementStillFocused: true)
            == .holdBack(.applicationChanged))
    }

    @Test func focusChangeDuringPrePasteDelayHoldsBack() async {
        // First read (quick check) matches; the read right before the command sees another app.
        let reader = FakeFocusReader(target(), target(pid: 300))
        let performer = FakePastePerformer()
        let presenter = FakeRecoveryPresenter()
        let paster = makePaster(reader: reader, performer: performer, presenter: presenter)

        let result = await paster.deliver("Text", sendKey: .enter, captured: target())

        #expect(result == .recovery(.heldBack(.applicationChanged)))
        #expect(performer.commandAttempts == 1)
        #expect(performer.pastedTexts.isEmpty)
        #expect(performer.sentKeys.isEmpty)
        #expect(presenter.presented.count == 1)
    }

    @Test func secureFieldHoldsBackEvenWithoutFocusChange() async {
        let secure = target(element: PasteFocusElement(
            identity: fieldA, role: "AXTextField", subrole: "AXSecureTextField", editable: true))
        let reader = FakeFocusReader(secure)
        let performer = FakePastePerformer()
        let presenter = FakeRecoveryPresenter()
        let paster = makePaster(reader: reader, performer: performer, presenter: presenter)

        let result = await paster.deliver("secret", sendKey: .none, captured: secure)

        #expect(result == .recovery(.heldBack(.secureField)))
        #expect(performer.commandAttempts == 0)
    }

    @Test func secureRoleIsDetected() {
        let current = target(element: PasteFocusElement(identity: fieldB, role: "AXSecureTextField"))
        #expect(PasteFocusGuard.decide(captured: nil, current: current) == .holdBack(.secureField))
    }

    @Test func nonEditableElementHoldsBack() async {
        let readOnly = target(element: PasteFocusElement(identity: fieldA, role: "AXStaticText", editable: false))
        let reader = FakeFocusReader(readOnly)
        let performer = FakePastePerformer()
        let presenter = FakeRecoveryPresenter()
        let paster = makePaster(reader: reader, performer: performer, presenter: presenter)

        let result = await paster.deliver("Text", sendKey: .none, captured: readOnly)

        #expect(result == .recovery(.heldBack(.notEditable)))
        #expect(performer.commandAttempts == 0)
    }

    @Test func unknownFieldStatePastesAsToday() async {
        // Electron, terminals and web views may expose no focused element or window.
        let unknown = target(window: nil, element: nil)
        let reader = FakeFocusReader(unknown)
        let performer = FakePastePerformer()
        let presenter = FakeRecoveryPresenter()
        let paster = makePaster(reader: reader, performer: performer, presenter: presenter)

        let result = await paster.deliver("Text", sendKey: .enter, captured: unknown)

        #expect(result == .pasted(.unverified))
        #expect(performer.pastedTexts == ["Text"])
        #expect(performer.sentKeys == [.enter])
        #expect(presenter.presented.isEmpty)
        #expect(reader.fieldReads == 0)
    }

    @Test func unknownEditabilityIsNotUnsafe() {
        let generic = target(element: PasteFocusElement(identity: fieldA, role: "AXGroup", editable: nil))
        #expect(PasteFocusGuard.decide(captured: generic, current: generic) == .proceed)
        // Element known on one side only is unknown, not a change.
        #expect(PasteFocusGuard.decide(captured: target(element: nil), current: generic) == .proceed)
        #expect(PasteFocusGuard.decide(captured: nil, current: generic) == .proceed)
    }

    @Test func guardOffPastesUnconditionally() async {
        let reader = FakeFocusReader(target(pid: 999))
        let performer = FakePastePerformer()
        let presenter = FakeRecoveryPresenter()
        let paster = makePaster(reader: reader, performer: performer, presenter: presenter, guardEnabled: false)

        let result = await paster.deliver("Text", sendKey: .enter, captured: target())

        #expect(result == .pasted(.unverified))
        #expect(performer.pastedTexts == ["Text"])
        #expect(performer.sentKeys == [.enter])
        #expect(presenter.presented.isEmpty)
        #expect(reader.targetReads == 0)
    }

    @Test func guardOffShowsNoCardWhenPasteFails() async {
        let performer = FakePastePerformer()
        performer.result = .commandNotPosted
        let presenter = FakeRecoveryPresenter()
        let paster = makePaster(
            reader: FakeFocusReader(target()), performer: performer, presenter: presenter, guardEnabled: false)

        _ = await paster.deliver("Text", sendKey: .enter, captured: nil)

        #expect(presenter.presented.isEmpty)
        #expect(performer.sentKeys.isEmpty)
    }
}

// MARK: - Post-paste verification

@MainActor
@Suite("Focus-safe paste: verification")
struct FocusSafePasteVerificationTests {
    @Test func unchangedReadableFieldCountsAsNotLanded() async {
        let reader = FakeFocusReader(target())
        reader.fieldValues = [PasteFieldState(value: "Before")]
        let performer = FakePastePerformer()
        let presenter = FakeRecoveryPresenter()
        let paster = makePaster(reader: reader, performer: performer, presenter: presenter)

        let result = await paster.deliver("Text", sendKey: .enter, captured: target())

        #expect(result == .recovery(.notLanded))
        #expect(performer.sentKeys.isEmpty)
        #expect(presenter.presented.first?.reason == .notLanded)
    }

    @Test func fieldUnreadableAfterPasteStaysUnverified() async {
        let reader = FakeFocusReader(target())
        reader.fieldValues = [PasteFieldState(value: "Before"), nil]
        let presenter = FakeRecoveryPresenter()
        let paster = makePaster(reader: reader, performer: FakePastePerformer(), presenter: presenter)

        let result = await paster.deliver("Text", sendKey: .none, captured: target())

        #expect(result == .pasted(.unverified))
        #expect(presenter.presented.isEmpty)
    }

    @Test func lateValueChangeStillCountsAsLanded() async {
        let unchanged = PasteFieldState(value: "Before")
        let reads = [unchanged, unchanged, PasteFieldState(value: "BeforeText")]
        var readCount = 0
        let verification = await PasteInsertionVerifier.verify(
            before: unchanged, insertedText: "Text", pollInterval: 0.01, timeout: 0.05, sleep: { _ in }
        ) {
            defer { readCount += 1 }
            return reads[min(readCount, reads.count - 1)]
        }
        #expect(verification == .landed)
        #expect(readCount == 3)
    }

    @Test func replacingIdenticalSelectionIsUnverified() async {
        let before = PasteFieldState(value: "Same", selectedText: "Same")
        let verification = await PasteInsertionVerifier.verify(
            before: before, insertedText: "Same", sleep: { _ in }
        ) { PasteFieldState(value: "Same") }
        #expect(verification == .unverified)
    }

    @Test(arguments: [
        (CursorPaster.PasteResult.commandNotPosted, PasteRecoveryReason.notPosted),
        (CursorPaster.PasteResult.commandPartiallyPosted, PasteRecoveryReason.partiallyPosted),
    ])
    func failedPasteShowsRecoveryCard(result: CursorPaster.PasteResult, reason: PasteRecoveryReason) async {
        let performer = FakePastePerformer()
        performer.result = result
        let presenter = FakeRecoveryPresenter()
        let paster = makePaster(reader: FakeFocusReader(target()), performer: performer, presenter: presenter)

        let outcome = await paster.deliver("Text", sendKey: .enter, captured: target())

        #expect(outcome == .recovery(reason))
        #expect(performer.sentKeys.isEmpty)
        #expect(presenter.presented.map(\.text) == ["Text"])
    }
}

// MARK: - Recovery card

@MainActor
@Suite("Focus-safe paste: recovery card")
struct PasteRecoveryCardTests {
    private final class Recorder {
        var pasted: [String] = []
        var copied: [String] = []
    }

    private func makeController(_ recorder: Recorder) -> PasteRecoveryCardController {
        PasteRecoveryCardController(
            presentsPanel: false,
            pasteText: { recorder.pasted.append($0) },
            copyText: { recorder.copied.append($0); return true }
        )
    }

    @Test func presentShowsTranscript() {
        let controller = makeController(Recorder())
        controller.present(text: "Hello", reason: .heldBack(.windowChanged))

        #expect(controller.card?.text == "Hello")
        #expect(controller.card?.reason == .heldBack(.windowChanged))
    }

    @Test func pasteInsertsTranscriptAndDismisses() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        controller.present(text: "Hello", reason: .notLanded)

        controller.paste()

        #expect(recorder.pasted == ["Hello"])
        #expect(recorder.copied.isEmpty)
        #expect(controller.card == nil)
    }

    @Test func copyCopiesTranscriptAndDismisses() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        controller.present(text: "Hello", reason: .heldBack(.secureField))

        controller.copy()

        #expect(recorder.copied == ["Hello"])
        #expect(recorder.pasted.isEmpty)
        #expect(controller.card == nil)
    }

    @Test func dismissClosesWithoutDelivering() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        controller.present(text: "Hello", reason: .notPosted)

        controller.dismiss()

        #expect(controller.card == nil)
        #expect(recorder.pasted.isEmpty && recorder.copied.isEmpty)
        // Actions without a card do nothing.
        controller.paste()
        #expect(recorder.pasted.isEmpty)
    }

    @Test func newerTranscriptReplacesCard() {
        let controller = makeController(Recorder())
        controller.present(text: "First", reason: .notPosted)
        controller.present(text: "Second", reason: .notLanded)

        #expect(controller.card?.text == "Second")
    }

    @Test func messagesAvoidDisallowedPunctuation() {
        let reasons: [PasteRecoveryReason] = [
            .heldBack(.applicationChanged), .heldBack(.windowChanged), .heldBack(.fieldChanged),
            .heldBack(.secureField), .heldBack(.notEditable), .notPosted, .partiallyPosted, .notLanded,
        ]
        for reason in reasons {
            #expect(!reason.message.contains("\u{2014}"))
            #expect(!reason.message.contains("\u{00B7}"))
        }
    }
}
