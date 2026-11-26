import SwiftData
import SwiftUI

/// The Android apps whose phone dictations use this mode.
struct ModeAndroidAppsSection: View {
    @Binding var androidAppConfigs: [AndroidAppConfig]
    let modeId: UUID

    @State private var isShowingPicker = false

    /// Recent phone dictations that recorded the app they went to.
    @Query(Self.phoneHistoryDescriptor()) private var phoneHistory: [Transcription]

    private static func phoneHistoryDescriptor() -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            predicate: #Predicate<Transcription> { $0.sourceApp != nil },
            sortBy: [SortDescriptor(\Transcription.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 300
        return descriptor
    }

    private var recentApps: [RecentAndroidApp] {
        RecentAndroidAppsStore.merged(
            recorded: RecentAndroidAppsStore.shared.apps,
            historyPackages: phoneHistory.compactMap { entry in
                entry.sourceApp.map { (packageName: $0, date: entry.timestamp) }
            }
        )
    }

    var body: some View {
        Section {
            if androidAppConfigs.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("No Android apps")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.vertical, 4)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(androidAppConfigs) { config in
                        AndroidAppChip(config: config) {
                            androidAppConfigs.removeRule(for: config.packageName)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack {
                HStack(spacing: 4) {
                    Text("Android apps")
                    InfoTip(
                        "Phone dictations into these Android apps use this mode. If several modes list the same app, the first enabled one in the mode list wins. Other apps use the Default mode."
                    )
                }

                Spacer()

                AddIconButton(helpText: "Add Android app") {
                    isShowingPicker = true
                }
                .popover(isPresented: $isShowingPicker, arrowEdge: .bottom) {
                    AndroidAppPickerPopover(
                        androidAppConfigs: $androidAppConfigs,
                        recentApps: recentApps,
                        currentModeId: modeId
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct AndroidAppChip: View {
    let config: AndroidAppConfig
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "smartphone")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(config.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("Remove Android app")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(AppCardBackground(cornerRadius: 7))
        .help(config.packageName)
    }
}

private struct AndroidAppPickerPopover: View {
    @Binding var androidAppConfigs: [AndroidAppConfig]
    let recentApps: [RecentAndroidApp]
    let currentModeId: UUID

    @State private var packageText = ""
    @FocusState private var isFieldFocused: Bool

    private var typedPackage: String {
        packageText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var typedPackageIsValid: Bool {
        PhoneDictationRequestContext.validatedApp(typedPackage) != nil
    }

    private var otherConfigurations: [ModeConfig] {
        ModeManager.shared.configurations.filter { $0.id != currentModeId }
    }

    private func otherMode(mapping packageName: String) -> ModeConfig? {
        otherConfigurations.first { $0.hasAndroidAppRule(for: packageName) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Package name, for example com.whatsapp", text: $packageText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($isFieldFocused)
                        .onSubmit(addTypedPackage)

                    Button("Add", action: addTypedPackage)
                        .disabled(!typedPackageIsValid || androidAppConfigs.containsRule(for: typedPackage))
                }

                if !typedPackage.isEmpty {
                    if !typedPackageIsValid {
                        Text("Not a valid Android package name.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else if androidAppConfigs.containsRule(for: typedPackage) {
                        Text("Already in this mode.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)

            Divider()

            Text("Recent on your phone")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)

            ScrollView {
                LazyVStack(spacing: 4) {
                    if recentApps.isEmpty {
                        Text("No phone dictations into apps yet. Dictate into an app on your phone and it appears here.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .padding(.horizontal, 12)
                    } else {
                        ForEach(recentApps) { app in
                            recentAppRow(app)
                        }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 340, height: 400)
        .onAppear {
            DispatchQueue.main.async {
                isFieldFocused = true
            }
        }
    }

    private func recentAppRow(_ app: RecentAndroidApp) -> some View {
        let isSelected = androidAppConfigs.containsRule(for: app.packageName)
        let otherMode = otherMode(mapping: app.packageName)

        return Button {
            if isSelected {
                androidAppConfigs.removeRule(for: app.packageName)
            } else {
                androidAppConfigs.addRule(packageName: app.packageName, appName: app.appName)
            }
        } label: {
            HStack(spacing: 10) {
                TriggerSymbol(systemName: "smartphone")

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if app.displayName != app.packageName {
                        Text(app.packageName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let otherMode {
                        Text("Also in \"\(otherMode.name)\"")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8).fill(
                    isSelected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private func addTypedPackage() {
        let package = typedPackage
        let known = recentApps.first { $0.packageName == package }?.appName
        if androidAppConfigs.addRule(packageName: package, appName: known) {
            packageText = ""
        }
    }
}
