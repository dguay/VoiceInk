import Foundation
import SwiftData

/// `POST /v1/corrections`: what the phone saw in the field it typed a dictation into, right after
/// typing it and when the user left the field. Every text is a bounded window around the inserted
/// text, cut on the phone. See docs/phone-dictation-api.md.
struct PhoneDictationCorrectionRequest: Codable, Equatable {
    /// The History `id` returned by `POST /v1/transcribe`.
    let id: UUID
    /// The dictated text as it was typed into the field.
    let insertedText: String
    /// The window of field text right after the insert.
    let textAfterInsert: String
    /// The same window of field text when the user left the field.
    let textWhenLeft: String
    /// Where `insertedText` starts in `textAfterInsert`, in UTF-16 code units.
    let insertStart: Int

    enum ValidationError: Error, Equatable {
        case invalid(String)

        var message: String {
            switch self {
            case .invalid(let message): return message
            }
        }
    }

    /// Decodes and checks a request body; the message of a failure is safe to return to the phone.
    static func decode(_ body: Data) -> Result<PhoneDictationCorrectionRequest, ValidationError> {
        guard let request = try? JSONDecoder().decode(PhoneDictationCorrectionRequest.self, from: body) else {
            return .failure(.invalid("The correction is not valid JSON with the documented fields."))
        }
        if let problem = request.problem {
            return .failure(.invalid(problem))
        }
        return .success(request)
    }

    private var problem: String? {
        let inserted = insertedText as NSString
        let after = textAfterInsert as NSString
        let limit = PhoneDictationAPI.maxCorrectionTextLength
        guard inserted.length > 0 else { return "insertedText is empty." }
        guard inserted.length <= AutoLearnLimits.maximumPastedCharacters else { return "insertedText is too long." }
        guard after.length <= limit, (textWhenLeft as NSString).length <= limit else {
            return "The field text is longer than \(limit) characters."
        }
        guard insertStart >= 0, insertStart <= after.length - inserted.length else {
            return "insertStart is outside textAfterInsert."
        }
        let range = NSRange(location: insertStart, length: inserted.length)
        guard after.substring(with: range).utf16.elementsEqual(insertedText.utf16) else {
            return "textAfterInsert does not contain insertedText at insertStart."
        }
        return nil
    }

    /// The same snapshot a paste observed on the Mac produces.
    var fieldSnapshot: AutoLearnFieldSnapshot {
        AutoLearnFieldSnapshot(
            baselineFieldText: textAfterInsert,
            finalFieldText: textWhenLeft,
            pastedRange: NSRange(location: insertStart, length: (insertedText as NSString).length),
            originalPastedText: insertedText
        )
    }
}

/// The `200` body of `POST /v1/corrections`.
struct PhoneDictationCorrectionBody: Codable, Equatable {
    let status: String
    /// False when Auto-Learn is off on the Mac: the correction was accepted and dropped.
    let autoLearnEnabled: Bool
}

enum PhoneDictationCorrectionOutcome: Equatable {
    case accepted(autoLearnEnabled: Bool)
    case unknownDictation
    case notPhoneDictation
}

/// Checks a correction against History and hands it to Auto-Learn.
@MainActor
final class PhoneDictationCorrectionIntake {
    /// Corrections already taken, so a phone retrying after a lost response is not counted twice.
    private var received: [UUID] = []
    private static let rememberedCount = 200

    private let modelContext: ModelContext
    private let learn: (AutoLearnFieldSnapshot) async -> Bool

    init(
        modelContext: ModelContext,
        learn: @escaping (AutoLearnFieldSnapshot) async -> Bool = {
            await AutoLearnService.shared.learnFromExternalSnapshot($0)
        }
    ) {
        self.modelContext = modelContext
        self.learn = learn
    }

    func submit(_ request: PhoneDictationCorrectionRequest) async -> PhoneDictationCorrectionOutcome {
        let id = request.id
        var descriptor = FetchDescriptor<Transcription>(predicate: #Predicate<Transcription> { $0.id == id })
        descriptor.fetchLimit = 1
        guard let transcription = (try? modelContext.fetch(descriptor))?.first else {
            return .unknownDictation
        }
        guard transcription.transcriptionSource == .phone else { return .notPhoneDictation }

        guard !received.contains(id) else {
            return .accepted(autoLearnEnabled: UserDefaults.standard.bool(forKey: AutoLearnSettings.isEnabledKey))
        }
        let enabled = await learn(request.fieldSnapshot)
        if enabled {
            received.append(id)
            if received.count > Self.rememberedCount { received.removeFirst() }
        }
        return .accepted(autoLearnEnabled: enabled)
    }
}

extension PhoneDictationCorrectionOutcome {
    var response: PhoneDictationHTTPResponse {
        switch self {
        case .accepted(let enabled):
            return .json(PhoneDictationCorrectionBody(status: "accepted", autoLearnEnabled: enabled))
        case .unknownDictation:
            return .error(.unknownDictation)
        case .notPhoneDictation:
            return .error(.notPhoneDictation)
        }
    }
}
