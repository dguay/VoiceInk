import Foundation

/// A candidate Whisper language for subset-constrained auto-detection.
struct WhisperLanguageCandidate: Equatable, Sendable {
    let languageID: Int32
    let code: String
}

/// Pure probability-distribution selector for Whisper scoped auto-detect.
enum WhisperAutoDetectLanguageSelector {
    /// Picks strictly the highest-probability language from `allowedCandidates`
    /// given Whisper's full probability vector (indexed by Whisper language ID).
    ///
    /// - Never returns a language outside `allowedCandidates`.
    /// - Non-finite probabilities (`NaN`, `±infinity`) never beat a finite probability.
    /// - Deterministic tie-breaking: the earliest candidate in `allowedCandidates` wins.
    /// - Returns `nil` only when `allowedCandidates` is empty.
    static func selectBestLanguage(
        probabilities: [Float],
        allowedCandidates: [WhisperLanguageCandidate]
    ) -> WhisperLanguageCandidate? {
        guard let fallback = allowedCandidates.first else {
            return nil
        }

        var bestCandidate: WhisperLanguageCandidate?
        var bestProbability: Float = -.greatestFiniteMagnitude

        for candidate in allowedCandidates {
            let index = Int(candidate.languageID)
            guard index >= 0, index < probabilities.count else { continue }
            let probability = probabilities[index]
            guard probability.isFinite else { continue }

            if bestCandidate == nil || probability > bestProbability {
                bestCandidate = candidate
                bestProbability = probability
            }
        }

        return bestCandidate ?? fallback
    }
}

/// Normalization, model compatibility, display labels, and AI prompt formatting
/// for subset-constrained Auto-detect languages.
enum AutoDetectLanguageScope {
    /// Trims, strips empty values and `"auto"`, and deduplicates case-insensitively
    /// while preserving order.
    static func normalize(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(codes.count)

        for raw in codes {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard key != "auto" else { continue }
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }

        return result
    }

    /// Returns `nil` when empty so encoded configs omit the field when unconstrained.
    static func normalizedOrNil(_ codes: [String]?) -> [String]? {
        guard let codes else { return nil }
        let normalized = normalize(codes)
        return normalized.isEmpty ? nil : normalized
    }

    /// Whether `model` supports Auto-detect at all.
    static func supportsAutoDetect(model: any TranscriptionModel, realtimeEnabled: Bool? = nil) -> Bool {
        TranscriptionLanguageSupport.languages(for: model, realtimeEnabled: realtimeEnabled)["auto"] != nil
    }

    /// Whether `model` natively constrains speech-recognition language identification
    /// to a configured subset before transcribing.
    static func supportsNativeScopedAutoDetect(model: any TranscriptionModel, realtimeEnabled: Bool? = nil) -> Bool {
        model.provider == .whisper
            && model.isMultilingualModel
            && supportsAutoDetect(model: model, realtimeEnabled: realtimeEnabled)
    }

    /// Selectable languages for `model` (excluding `"auto"`), sorted alphabetically by name.
    static func supportedOptions(
        for model: any TranscriptionModel,
        realtimeEnabled: Bool? = nil
    ) -> [(code: String, name: String)] {
        TranscriptionLanguageSupport.languages(for: model, realtimeEnabled: realtimeEnabled)
            .filter { $0.key != "auto" }
            .map { (code: $0.key, name: $0.value) }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if order == .orderedSame {
                    return lhs.code < rhs.code
                }
                return order == .orderedAscending
            }
    }

    /// Reconciles configured codes against `model`'s supported languages (excluding `"auto"`).
    /// Matches exact codes first (case-insensitively), then primary language subtags
    /// (for example `fr-CA` <-> `fr` or `en` <-> `en-US`).
    static func reconcile(
        _ codes: [String],
        for model: any TranscriptionModel,
        realtimeEnabled: Bool? = nil
    ) -> [String] {
        let supported = TranscriptionLanguageSupport.languages(for: model, realtimeEnabled: realtimeEnabled)
            .filter { $0.key != "auto" }
        return reconcile(codes, against: supported)
    }

    static func reconcile(_ codes: [String], against supportedLanguages: [String: String]) -> [String] {
        let validLanguages = supportedLanguages.filter { $0.key != "auto" }
        guard !validLanguages.isEmpty else { return [] }

        var exactByLowercase: [String: String] = [:]
        var candidatesByBase: [String: [String]] = [:]
        for key in validLanguages.keys.sorted() {
            exactByLowercase[key.lowercased()] = key
            let base = primaryLanguageSubtag(of: key)
            candidatesByBase[base, default: []].append(key)
        }

        var seen = Set<String>()
        var reconciled: [String] = []

        for code in normalize(codes) {
            let lower = code.lowercased()
            let matched: String?
            if let exact = exactByLowercase[lower] {
                matched = exact
            } else {
                let base = primaryLanguageSubtag(of: lower)
                if let exactBase = exactByLowercase[base] {
                    matched = exactBase
                } else if let regionalMatches = candidatesByBase[base], !regionalMatches.isEmpty {
                    matched = preferredRegionalVariant(from: regionalMatches, base: base)
                } else {
                    matched = nil
                }
            }

            if let matched, seen.insert(matched.lowercased()).inserted {
                reconciled.append(matched)
            }
        }

        return reconciled
    }

    /// Returns the active allowed languages for transcription. Empty unless `selectedLanguage == "auto"`.
    static func effectiveAllowedLanguages(
        selectedLanguage: String?,
        configuredAllowedLanguages: [String]?,
        for model: any TranscriptionModel,
        realtimeEnabled: Bool? = nil
    ) -> [String] {
        guard selectedLanguage == "auto",
            supportsAutoDetect(model: model, realtimeEnabled: realtimeEnabled),
            let configured = configuredAllowedLanguages,
            !configured.isEmpty
        else {
            return []
        }

        return reconcile(configured, for: model, realtimeEnabled: realtimeEnabled)
    }

    /// Primary language subtag before `-` or `_`, lowercased (e.g. `fr-CA` -> `fr`).
    static func primaryLanguageSubtag(of code: String) -> String {
        let lower = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let separator = lower.firstIndex { $0 == "-" || $0 == "_" }
        return separator.map { String(lower[..<$0]) } ?? lower
    }

    static func displayName(
        for code: String,
        supportedLanguages: [String: String] = LanguageDictionary.all
    ) -> String {
        if let exact = supportedLanguages[code] {
            return exact
        }
        if let exactAll = LanguageDictionary.all[code] {
            return exactAll
        }
        let base = primaryLanguageSubtag(of: code)
        if let baseName = supportedLanguages[base] ?? LanguageDictionary.all[base] {
            return baseName
        }
        if let localized = Locale.current.localizedString(forLanguageCode: code), !localized.isEmpty {
            return localized
        }
        return code.uppercased()
    }

    /// Compact label for Mode cards (e.g. `Auto`, `Auto (EN, FR)`, or `Auto (3 languages)`).
    static func badgeLabel(
        for allowedCodes: [String]?,
        supportedLanguages: [String: String] = LanguageDictionary.all
    ) -> String {
        let normalized = normalize(allowedCodes ?? [])
        guard !normalized.isEmpty else {
            return String(localized: "Auto")
        }

        if normalized.count <= 2 {
            let shortCodes = normalized.map { code -> String in
                let base = primaryLanguageSubtag(of: code)
                return base.uppercased()
            }
            return String(
                format: String(localized: "Auto (%@)"),
                shortCodes.joined(separator: ", ")
            )
        }

        return String(localized: "Auto (\(normalized.count) languages)")
    }

    /// Honest compatibility note shown in language settings.
    static func compatibilityHint(
        for model: any TranscriptionModel,
        hasAllowedLanguages: Bool,
        realtimeEnabled: Bool? = nil
    ) -> String {
        if supportsNativeScopedAutoDetect(model: model, realtimeEnabled: realtimeEnabled) {
            if hasAllowedLanguages {
                return String(
                    localized:
                        "Whisper selects strictly from these languages before transcribing. AI cleanup also keeps output in these languages."
                )
            }
            return String(
                localized:
                    "Leave empty to detect across all languages supported by this model."
            )
        }

        return String(
            format: String(
                localized:
                    "Full speech-recognition scoping applies to local Whisper models. For %@, this list is enforced by AI cleanup when enabled."
            ),
            model.displayName
        )
    }

    /// AI enhancement system-prompt constraint block. Empty when unconstrained.
    static func enhancementSection(for codes: [String]) -> String {
        let normalized = normalize(codes)
        guard !normalized.isEmpty else { return "" }

        let formatted = normalized.map { code -> String in
            let name = displayName(for: code)
            if name.caseInsensitiveCompare(code) == .orderedSame {
                return code
            }
            return "\(name) (\(code))"
        }.joined(separator: ", ")

        return """
            <ALLOWED_LANGUAGES>
            The speaker uses only these languages: \(formatted).
            Keep the cleaned output strictly in the spoken language(s) from this list. Preserve natural code-switching between allowed languages when present. Do not translate into another language or drift into any language outside this list.
            </ALLOWED_LANGUAGES>
            """
    }

    private static func preferredRegionalVariant(from variants: [String], base: String) -> String {
        let preferredByBase: [String: String] = [
            "en": "en-US",
            "fr": "fr-FR",
            "es": "es-ES",
            "pt": "pt-BR",
            "zh": "zh-CN",
            "de": "de-DE",
            "it": "it-IT",
        ]
        if let preferred = preferredByBase[base],
            let match = variants.first(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame })
        {
            return match
        }
        return variants[0]
    }
}
