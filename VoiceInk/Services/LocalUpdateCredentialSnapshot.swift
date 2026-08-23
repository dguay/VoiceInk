import Foundation
import Security

protocol ForkUpdateCredentialSnapshotting {
    func createSnapshot(generationIdentifier: String) throws
    func deleteSnapshot(generationIdentifier: String) throws
}

protocol ForkUpdateCredentialRestoring {
    func restoreSnapshot(generationIdentifier: String) throws
}

enum LocalUpdateCredentialRecoveryCommand {
    static let createArgument = "--voiceink-create-update-credentials"
    static let deleteArgument = "--voiceink-delete-update-credentials"
    static let restoreArgument = "--voiceink-restore-update-credentials"

    static func runIfRequested(
        arguments: [String] = CommandLine.arguments,
        credentialStore: any ForkUpdateCredentialSnapshotting & ForkUpdateCredentialRestoring =
            LocalUpdateCredentialSnapshotStore()
    ) throws -> Bool {
        for (argument, action) in [
            (createArgument, credentialStore.createSnapshot),
            (deleteArgument, credentialStore.deleteSnapshot),
            (restoreArgument, credentialStore.restoreSnapshot),
        ] {
            guard let index = arguments.firstIndex(of: argument) else { continue }
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else {
                throw ForkUpdateError(message: "VoiceInk received an updater credential command without a generation identifier.")
            }
            try action(try validatedGenerationIdentifier(arguments[valueIndex]))
            return true
        }
        return false
    }

    private static func validatedGenerationIdentifier(_ value: String) throws -> String {
        guard UUID(uuidString: value) != nil else {
            throw ForkUpdateError(message: "VoiceInk received an invalid updater credential generation identifier.")
        }
        return value.lowercased()
    }
}

struct LocalUpdateCredentialSnapshotStore: ForkUpdateCredentialSnapshotting, ForkUpdateCredentialRestoring {
    private struct Record: Codable {
        let account: String
        let data: Data
        let accessibility: String?
    }

    private static let credentialService = "com.prakashjoshipax.VoiceInk.Local"
    private static let snapshotService = "com.prakashjoshipax.VoiceInk.Local.UpdaterRecovery"
    private static let snapshotAccountPrefix = "credentials."

    func createSnapshot(generationIdentifier: String) throws {
        let records = try readRecords(service: Self.credentialService)
        try write(
            PropertyListEncoder().encode(records),
            account: snapshotAccount(generationIdentifier),
            service: Self.snapshotService,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func deleteSnapshot(generationIdentifier: String) throws {
        let status = SecItemDelete(
            query(
                account: snapshotAccount(generationIdentifier),
                service: Self.snapshotService
            ) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw error(operation: "delete an obsolete updater credential snapshot", status: status)
        }
    }

    func restoreSnapshot(generationIdentifier: String) throws {
        let snapshot = try read(
            account: snapshotAccount(generationIdentifier),
            service: Self.snapshotService
        )
        let records = try PropertyListDecoder().decode([Record].self, from: snapshot)
        let rejectedRecords = try readRecords(service: Self.credentialService)

        do {
            try replaceCredentials(with: records)
        } catch let restorationError {
            do {
                try replaceCredentials(with: rejectedRecords)
            } catch {
                throw ForkUpdateError(
                    message: "VoiceInk could not restore credentials or compensate the partial Keychain update."
                )
            }
            throw restorationError
        }
    }

    private func snapshotAccount(_ generationIdentifier: String) -> String {
        Self.snapshotAccountPrefix + generationIdentifier.lowercased()
    }

    private func replaceCredentials(with records: [Record]) throws {
        let restoredAccounts = Set(records.map(\.account))

        for record in records {
            try write(
                record.data,
                account: record.account,
                service: Self.credentialService,
                accessibility: record.accessibility
            )
        }
        for current in try readRecords(service: Self.credentialService) where !restoredAccounts.contains(current.account) {
            let status = SecItemDelete(query(account: current.account, service: Self.credentialService) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw error(operation: "remove credentials added by the rejected update", status: status)
            }
        }
    }

    private func readRecords(service: String) throws -> [Record] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw error(operation: "read credentials", status: status)
        }

        return try items.map { item in
            guard
                let account = item[kSecAttrAccount as String] as? String,
                let data = item[kSecValueData as String] as? Data
            else {
                throw ForkUpdateError(message: "VoiceInk could not decode its credential snapshot.")
            }
            return Record(
                account: account,
                data: data,
                accessibility: item[kSecAttrAccessible as String] as? String
            )
        }
    }

    private func read(account: String, service: String) throws -> Data {
        var query = query(account: account, service: service)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw error(operation: "read the updater credential snapshot", status: status)
        }
        return data
    }

    private func write(
        _ data: Data,
        account: String,
        service: String,
        accessibility: String?
    ) throws {
        let itemQuery = query(account: account, service: service)
        var attributes: [String: Any] = [kSecValueData as String: data]
        if let accessibility {
            attributes[kSecAttrAccessible as String] = accessibility
        }

        let updateStatus = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw error(operation: "update the credential snapshot", status: updateStatus)
        }

        var addQuery = itemQuery
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw error(operation: "store the credential snapshot", status: addStatus)
        }
    }

    private func query(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func error(operation: String, status: OSStatus) -> ForkUpdateError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return ForkUpdateError(message: "VoiceInk could not \(operation): \(detail).")
    }
}

struct LocalUpdateRecoveryReconciler {
    private let fileManager: FileManager
    private let credentialStore: any ForkUpdateCredentialSnapshotting

    init(
        fileManager: FileManager = .default,
        credentialStore: any ForkUpdateCredentialSnapshotting = LocalUpdateCredentialSnapshotStore()
    ) {
        self.fileManager = fileManager
        self.credentialStore = credentialStore
    }

    func reconcile(
        installedBundleURL: URL = Bundle.main.bundleURL,
        recoveryRootURL: URL? = nil
    ) throws {
        let root = recoveryRootURL ?? defaultRecoveryRootURL()
        let pending = URL(fileURLWithPath: root.path + ".pending", isDirectory: true)
        let previous = URL(fileURLWithPath: root.path + ".previous", isDirectory: true)
        guard fileManager.fileExists(atPath: root.path)
                || fileManager.fileExists(atPath: pending.path)
                || fileManager.fileExists(atPath: previous.path)
        else {
            return
        }
        let installedCommit = try installedForkCommit(at: installedBundleURL)

        if let state = try state(at: pending), isSettled(state, installedCommit: installedCommit) {
            try activatePending(pending, root: root, previous: previous, generation: state.credentialGeneration)
            return
        }
        if let state = try state(at: root), isSettled(state, installedCommit: installedCommit) {
            try removeRecovery(at: pending, preserving: state.credentialGeneration)
            try removeRecovery(at: previous, preserving: state.credentialGeneration)
            return
        }
        if let state = try state(at: previous), isSettled(state, installedCommit: installedCommit) {
            try removeRecovery(at: root, preserving: state.credentialGeneration)
            try fileManager.moveItem(at: previous, to: root)
            try removeRecovery(at: pending, preserving: state.credentialGeneration)
            return
        }
        if let state = try state(at: pending), state.previousForkCommit == installedCommit {
            // Replacement never took effect. The installed app is still the
            // quiescent generation from which this pending snapshot was made.
            try removeRecovery(at: pending, preserving: nil)
            return
        }

        throw ForkUpdateError(
            message: "VoiceInk found an updater recovery transaction that does not match the installed app."
        )
    }

    private func activatePending(
        _ pending: URL,
        root: URL,
        previous: URL,
        generation: String
    ) throws {
        if fileManager.fileExists(atPath: previous.path) {
            try removeRecovery(at: previous, preserving: generation)
        }
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.moveItem(at: root, to: previous)
        }
        try fileManager.moveItem(at: pending, to: root)
        try removeRecovery(at: previous, preserving: generation)
    }

    private func removeRecovery(at url: URL, preserving generation: String?) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        if let obsoleteGeneration = try state(at: url)?.credentialGeneration,
           obsoleteGeneration != generation {
            try credentialStore.deleteSnapshot(generationIdentifier: obsoleteGeneration)
        }
        try fileManager.removeItem(at: url)
    }

    private func state(at recoveryURL: URL) throws -> LocalUpdateRecoveryState? {
        guard fileManager.fileExists(atPath: recoveryURL.path) else { return nil }
        let stateURL = recoveryURL.appendingPathComponent("recovery.plist")
        guard fileManager.fileExists(atPath: stateURL.path) else {
            throw ForkUpdateError(message: "VoiceInk found an updater recovery directory without valid metadata.")
        }
        return try PropertyListDecoder().decode(
            LocalUpdateRecoveryState.self,
            from: Data(contentsOf: stateURL)
        )
    }

    private func isSettled(_ state: LocalUpdateRecoveryState, installedCommit: String) -> Bool {
        state.candidateForkCommit == installedCommit
            || (state.previousForkCommit == installedCommit && state.suppressedForkCommit == state.candidateForkCommit)
    }

    private func defaultRecoveryRootURL() -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk.UpdaterRecovery", isDirectory: true)
    }

    private func installedForkCommit(at bundleURL: URL) throws -> String {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist"))
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let info = propertyList as? [String: Any],
              let commit = info[SourceProvenance.forkCommitInfoKey] as? String
        else {
            throw ForkUpdateError(message: "VoiceInk could not read the installed source revision.")
        }
        return commit
    }
}
