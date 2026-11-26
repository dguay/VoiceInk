import Foundation

/// An Android app seen in a recent phone dictation, offered when adding Android app rules to a mode.
struct RecentAndroidApp: Codable, Equatable, Identifiable {
    var packageName: String
    /// The readable name the phone sent with its latest dictation into the app, if any.
    var appName: String?
    var lastSeen: Date

    var id: String { packageName }

    /// The phone's name for the app, else a well-known name, else the package name.
    var displayName: String {
        appName ?? AndroidAppName.displayName(for: packageName)
    }
}

/// A small, bounded list of the Android apps phone dictations went to, newest first, with the
/// readable name the phone sent. It holds package names and labels only, never dictated text.
///
/// History (`Transcription.sourceApp`) already records the package of each phone dictation, but
/// not the phone's label, and History entries can be deleted or cleaned up. This store keeps the
/// labels; the mode editor merges it with the packages found in History (see `merged`).
final class RecentAndroidAppsStore {
    static let shared = RecentAndroidAppsStore()

    static let storageKey = "phoneDictationRecentAndroidApps"
    /// Most apps kept; the least recently seen are dropped first.
    static let maxCount = 30

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored apps, newest first.
    var apps: [RecentAndroidApp] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    /// Records a phone dictation into `packageName`. A missing `appName` keeps the name seen before.
    /// An invalid package name is ignored.
    func record(packageName: String, appName: String?, at date: Date = Date()) {
        guard let packageName = PhoneDictationRequestContext.validatedApp(packageName) else { return }
        let appName = appName.flatMap(PhoneDictationRequestContext.validatedAppName)
        lock.lock()
        defer { lock.unlock() }
        var apps = load()
        let previous = apps.first { $0.packageName == packageName }
        apps.removeAll { $0.packageName == packageName }
        apps.insert(
            RecentAndroidApp(packageName: packageName, appName: appName ?? previous?.appName, lastSeen: date), at: 0)
        save(Array(apps.prefix(Self.maxCount)))
    }

    /// `recorded` apps plus the packages of recent phone dictations in History (newest first, as
    /// `historyPackages`), without duplicates, newest first, at most `limit` apps. A History package
    /// that is not recorded gets a well-known name or is shown as is.
    static func merged(
        recorded: [RecentAndroidApp], historyPackages: [(packageName: String, date: Date)], limit: Int = maxCount
    ) -> [RecentAndroidApp] {
        var byPackage: [String: RecentAndroidApp] = [:]
        for app in recorded {
            byPackage[app.packageName] = app
        }
        for entry in historyPackages {
            guard let packageName = PhoneDictationRequestContext.validatedApp(entry.packageName) else { continue }
            if var existing = byPackage[packageName] {
                if entry.date > existing.lastSeen { existing.lastSeen = entry.date }
                byPackage[packageName] = existing
            } else {
                byPackage[packageName] = RecentAndroidApp(packageName: packageName, appName: nil, lastSeen: entry.date)
            }
        }
        return Array(
            byPackage.values.sorted { lhs, rhs in
                lhs.lastSeen != rhs.lastSeen ? lhs.lastSeen > rhs.lastSeen : lhs.packageName < rhs.packageName
            }
            .prefix(limit))
    }

    private func load() -> [RecentAndroidApp] {
        guard let data = defaults.data(forKey: Self.storageKey),
            let apps = try? JSONDecoder().decode([RecentAndroidApp].self, from: data)
        else { return [] }
        return apps
    }

    private func save(_ apps: [RecentAndroidApp]) {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
