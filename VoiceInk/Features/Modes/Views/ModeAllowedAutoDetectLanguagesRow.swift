import SwiftUI

/// Configures the optional subset of languages allowed when a mode uses Auto-detect.
struct ModeAllowedAutoDetectLanguagesRow: View {
    @Binding var allowedLanguages: [String]
    let model: any TranscriptionModel
    let realtimeEnabled: Bool

    @State private var isShowingPicker = false

    private var supportedLanguages: [String: String] {
        TranscriptionLanguageSupport.languages(for: model, realtimeEnabled: realtimeEnabled)
    }

    private var selectableOptions: [(code: String, name: String)] {
        AutoDetectLanguageScope.supportedOptions(for: model, realtimeEnabled: realtimeEnabled)
    }

    private var supportsNativeScoping: Bool {
        AutoDetectLanguageScope.supportsNativeScopedAutoDetect(
            model: model,
            realtimeEnabled: realtimeEnabled
        )
    }

    private var compatibilityHint: String {
        AutoDetectLanguageScope.compatibilityHint(
            for: model,
            hasAllowedLanguages: !allowedLanguages.isEmpty,
            realtimeEnabled: realtimeEnabled
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("Allowed auto-detect languages")
                    InfoTip(
                        "Restrict Auto-detect to the languages you actually speak. Leave empty to detect across all languages supported by the model."
                    )
                }

                Spacer(minLength: 8)

                if !allowedLanguages.isEmpty {
                    Button("Clear") {
                        allowedLanguages = []
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .help("Restore unconstrained auto-detect")
                }

                AddIconButton(helpText: "Select allowed auto-detect languages") {
                    isShowingPicker = true
                }
                .popover(isPresented: $isShowingPicker, arrowEdge: .bottom) {
                    AllowedAutoDetectLanguagesPopover(
                        allowedLanguages: $allowedLanguages,
                        options: selectableOptions
                    )
                }
            }

            if allowedLanguages.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("All supported languages")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(allowedLanguages, id: \.self) { code in
                        AllowedLanguageChip(
                            title: AutoDetectLanguageScope.displayName(
                                for: code,
                                supportedLanguages: supportedLanguages
                            ),
                            code: code
                        ) {
                            allowedLanguages.removeAll { $0.caseInsensitiveCompare(code) == .orderedSame }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            compatibilityNoteView
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var compatibilityNoteView: some View {
        if supportsNativeScoping {
            Text(compatibilityHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(allowedLanguages.isEmpty ? Color.secondary : AppTheme.Status.warningStrong)
                    .padding(.top, 1)

                Text(compatibilityHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        allowedLanguages.isEmpty
                            ? AppTheme.Surface.control.opacity(0.6)
                            : AppTheme.Status.warningStrong.opacity(0.08)
                    )
            )
        }
    }
}

private struct AllowedLanguageChip: View {
    let title: String
    let code: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("Remove \(title)")
            .accessibilityLabel("Remove \(title)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(AppCardBackground(cornerRadius: 7))
        .help("\(title) (\(code))")
    }
}

private struct AllowedAutoDetectLanguagesPopover: View {
    @Binding var allowedLanguages: [String]
    let options: [(code: String, name: String)]

    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredOptions: [(code: String, name: String)] {
        guard !trimmedQuery.isEmpty else { return options }
        return options.filter { option in
            option.name.localizedCaseInsensitiveContains(trimmedQuery)
                || option.code.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var selectedOptions: [(code: String, name: String)] {
        options.filter { isSelected($0.code) }
    }

    private func isSelected(_ code: String) -> Bool {
        allowedLanguages.contains { $0.caseInsensitiveCompare(code) == .orderedSame }
    }

    private func toggle(_ code: String) {
        if isSelected(code) {
            allowedLanguages.removeAll { $0.caseInsensitiveCompare(code) == .orderedSame }
        } else {
            allowedLanguages = AutoDetectLanguageScope.normalize(allowedLanguages + [code])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search languages", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($isSearchFocused)

                if !allowedLanguages.isEmpty {
                    HStack {
                        Text(String(localized: "\(allowedLanguages.count) selected"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Clear All") {
                            allowedLanguages = []
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if trimmedQuery.isEmpty && !selectedOptions.isEmpty {
                        Text("Selected")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 4)

                        ForEach(selectedOptions, id: \.code) { option in
                            languageRow(option)
                        }

                        Divider()
                            .padding(.vertical, 4)

                        Text("All Languages")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    }

                    if filteredOptions.isEmpty {
                        Text("No matching languages")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(filteredOptions, id: \.code) { option in
                            languageRow(option)
                        }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 300, height: 360)
        .onAppear {
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
    }

    private func languageRow(_ option: (code: String, name: String)) -> some View {
        let selected = isSelected(option.code)
        return Button {
            toggle(option.code)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(option.code)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 14, weight: selected ? .semibold : .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
