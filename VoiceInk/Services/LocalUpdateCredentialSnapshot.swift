import Foundation
import Security

protocol ForkUpdateCredentialSnapshotting {
    func createSnapshot() throws
}

protocol ForkUpdateCredentialRestoring {
    func restoreSnapshot() throws
}

enum LocalUpdateCredentialRecoveryCommand {
    static let argument = "--voiceink-restore-update-credentials"

    static func runIfRequested(
        arguments: [String] = CommandLine.arguments,
        credentialStore: any ForkUpdateCredentialRestoring = LocalUpdateCredentialSnapshotStore()
    ) throws -> Bool {
        guard arguments.contains(argument) else { return false }
        try credentialStore.restoreSnapshot()
        return true
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
    private static let snapshotAccount = "last-known-good-credentials"

    func createSnapshot() throws {
        let records = try readRecords(service: Self.credentialService)
        let snapshot = try PropertyListEncoder().encode(records)
        try write(
            snapshot,
            account: Self.snapshotAccount,
            service: Self.snapshotService,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func restoreSnapshot() throws {
        let snapshot = try read(account: Self.snapshotAccount, service: Self.snapshotService)
        let records = try PropertyListDecoder().decode([Record].self, from: snapshot)
        let restoredAccounts = Set(records.map(\.account))

        for record in records {
            try write(
                record.data,
                account: record.account,
                service: Self.credentialService,
                accessibility: record.accessibility
            )
        }

        for current in try readRecords(service: Self.credentialService)
        where !restoredAccounts.contains(current.account) {
            let status = SecItemDelete(query(account: current.account, service: Self.credentialService) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw error(operation: "remove credentials added by the rejected update", status: status)
            }
        }
    }

    func hasSnapshot() -> Bool {
        var query = query(account: Self.snapshotAccount, service: Self.snapshotService)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
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
        if status == errSecItemNotFound {
            return []
        }
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
        if updateStatus == errSecSuccess {
            return
        }
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
