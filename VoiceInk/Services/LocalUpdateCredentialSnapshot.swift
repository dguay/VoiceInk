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

struct LocalUpdateCredentialRecord: Codable, Equatable {
    let account: String
    let data: Data
    let accessibility: String?
}

protocol LocalUpdateCredentialPersisting {
    func readRecords(service: String) throws -> [LocalUpdateCredentialRecord]
    func read(account: String, service: String) throws -> Data
    func write(_ data: Data, account: String, service: String, accessibility: String?) throws
    func delete(account: String, service: String) throws
}

struct LocalUpdateCredentialSnapshotStore: ForkUpdateCredentialSnapshotting, ForkUpdateCredentialRestoring {
    private static let credentialService = "com.prakashjoshipax.VoiceInk.Local"
    private static let snapshotService = "com.prakashjoshipax.VoiceInk.Local.UpdaterRecovery"
    private static let snapshotAccountPrefix = "credentials."
    private let persistence: any LocalUpdateCredentialPersisting

    init(persistence: any LocalUpdateCredentialPersisting = SecurityLocalUpdateCredentialPersistence()) {
        self.persistence = persistence
    }

    func createSnapshot(generationIdentifier: String) throws {
        let records = try persistence.readRecords(service: Self.credentialService)
        try persistence.write(
            PropertyListEncoder().encode(records),
            account: snapshotAccount(generationIdentifier),
            service: Self.snapshotService,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func deleteSnapshot(generationIdentifier: String) throws {
        try persistence.delete(
            account: snapshotAccount(generationIdentifier),
            service: Self.snapshotService
        )
    }

    func restoreSnapshot(generationIdentifier: String) throws {
        let snapshot = try persistence.read(
            account: snapshotAccount(generationIdentifier),
            service: Self.snapshotService
        )
        let records = try PropertyListDecoder().decode([LocalUpdateCredentialRecord].self, from: snapshot)
        let rejectedRecords = try persistence.readRecords(service: Self.credentialService)

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

    private func replaceCredentials(with records: [LocalUpdateCredentialRecord]) throws {
        let restoredAccounts = Set(records.map(\.account))

        for record in records {
            try persistence.write(
                record.data,
                account: record.account,
                service: Self.credentialService,
                accessibility: record.accessibility
            )
        }
        for current in try persistence.readRecords(service: Self.credentialService)
            where !restoredAccounts.contains(current.account) {
            try persistence.delete(account: current.account, service: Self.credentialService)
        }
    }
}

struct SecurityLocalUpdateCredentialPersistence: LocalUpdateCredentialPersisting {
    func readRecords(service: String) throws -> [LocalUpdateCredentialRecord] {
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
            return LocalUpdateCredentialRecord(
                account: account,
                data: data,
                accessibility: item[kSecAttrAccessible as String] as? String
            )
        }
    }

    func read(account: String, service: String) throws -> Data {
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

    func write(
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

    func delete(account: String, service: String) throws {
        let status = SecItemDelete(query(account: account, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw error(operation: "delete a credential recovery item", status: status)
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
        let preparing = URL(fileURLWithPath: root.path + ".preparing", isDirectory: true)
        let pending = URL(fileURLWithPath: root.path + ".pending", isDirectory: true)
        let previous = URL(fileURLWithPath: root.path + ".previous", isDirectory: true)
        // A preparing directory is never Keychain-addressable: it is renamed to
        // pending before the credential snapshot is created. It is therefore
        // always safe to discard after an interrupted intent write.
        if fileManager.fileExists(atPath: preparing.path) {
            try fileManager.removeItem(at: preparing)
        }
        guard fileManager.fileExists(atPath: root.path)
                || fileManager.fileExists(atPath: pending.path)
                || fileManager.fileExists(atPath: previous.path)
        else {
            return
        }
        let installedCommit = try installedForkCommit(at: installedBundleURL)

        // Precedence is deliberate. A matching pending generation means bundle
        // replacement won but publication stopped. A matching root is already
        // authoritative. Previous is used only when publication moved root aside
        // before replacement took effect. A pending generation whose previous
        // commit is still installed never became active and is discarded.
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
        state.installInProgress != true
            && state.restoreInProgress != true
            && (state.candidateForkCommit == installedCommit
            || (state.previousForkCommit == installedCommit && state.suppressedForkCommit == state.candidateForkCommit)
            )
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

struct LocalUpdateRestoreResumer {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func resumeIfNeeded(
        installedBundleURL: URL = Bundle.main.bundleURL,
        recoveryRootURL: URL? = nil,
        restorationScriptURL: URL? = nil
    ) throws -> Bool {
        let root = recoveryRootURL ?? defaultRecoveryRootURL()
        let pending = URL(fileURLWithPath: root.path + ".pending", isDirectory: true)
        let previous = URL(fileURLWithPath: root.path + ".previous", isDirectory: true)
        let installedCommit = try installedForkCommitIfRecoveryExists(
            at: installedBundleURL,
            recoveryURLs: [pending, root, previous]
        )
        guard let installedCommit else { return false }

        let recoveryURL = try [pending, root, previous].first { url in
            guard let state = try state(at: url) else { return false }
            if state.restoreInProgress == true {
                return state.candidateForkCommit == installedCommit || state.previousForkCommit == installedCommit
            }
            return state.installInProgress == true && state.candidateForkCommit == installedCommit
        }
        guard let recoveryURL else { return false }
        guard let scriptURL = restorationScriptURL
            ?? Bundle.main.url(forResource: "restore-local-update", withExtension: "sh")
        else {
            throw ForkUpdateError(message: "VoiceInk could not find its interrupted rollback helper.")
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            scriptURL.path,
            "--resume",
            installedBundleURL.path,
            recoveryURL.appendingPathComponent("VoiceInk.app", isDirectory: true).path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ForkUpdateError(
                message: detail.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "VoiceInk could not resume its interrupted rollback."
            )
        }
        return true
    }

    private func state(at recoveryURL: URL) throws -> LocalUpdateRecoveryState? {
        let stateURL = recoveryURL.appendingPathComponent("recovery.plist")
        guard fileManager.fileExists(atPath: stateURL.path) else { return nil }
        return try PropertyListDecoder().decode(
            LocalUpdateRecoveryState.self,
            from: Data(contentsOf: stateURL)
        )
    }

    private func installedForkCommitIfRecoveryExists(
        at bundleURL: URL,
        recoveryURLs: [URL]
    ) throws -> String? {
        guard recoveryURLs.contains(where: { fileManager.fileExists(atPath: $0.path) }) else { return nil }
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        let propertyList = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL),
            options: [],
            format: nil
        )
        guard let info = propertyList as? [String: Any],
              let commit = info[SourceProvenance.forkCommitInfoKey] as? String
        else {
            throw ForkUpdateError(message: "VoiceInk could not read the installed source revision.")
        }
        return commit
    }

    private func defaultRecoveryRootURL() -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk.UpdaterRecovery", isDirectory: true)
    }
}
