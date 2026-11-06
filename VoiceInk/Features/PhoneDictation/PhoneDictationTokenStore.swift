import Foundation
import Security

/// Persistent storage for the pairing token.
protocol PhoneDictationTokenStorage: AnyObject {
    func readToken() -> String?
    func writeToken(_ token: String) -> Bool
}

/// Keeps the token in this Mac's Keychain only (never synced).
final class KeychainPhoneDictationTokenStorage: PhoneDictationTokenStorage {
    private let key = "phoneDictationPairingToken"

    func readToken() -> String? {
        KeychainService.shared.getString(forKey: key, syncable: false)
    }

    func writeToken(_ token: String) -> Bool {
        KeychainService.shared.save(
            token, forKey: key, syncable: false, accessibility: .afterFirstUnlockThisDeviceOnly)
    }
}

enum PhoneDictationTokenError: Error, LocalizedError {
    case storageFailed
    case randomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .storageFailed:
            return String(localized: "The pairing token could not be saved to the Keychain.")
        case .randomGenerationFailed:
            return String(localized: "A secure pairing token could not be generated.")
        }
    }
}

/// The current pairing token. Validation is thread-safe and reads the in-memory copy, so a
/// regenerated token takes effect for the next request.
final class PhoneDictationTokenStore: @unchecked Sendable {
    private let storage: PhoneDictationTokenStorage
    private let lock = NSLock()
    private var cachedToken: String?
    private var hasLoaded = false

    init(storage: PhoneDictationTokenStorage) {
        self.storage = storage
    }

    /// The stored token, created and saved on first use.
    func currentToken() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let token = loadLocked() {
            return token
        }
        return try replaceLocked()
    }

    /// Replaces the token; the previous one stops working immediately.
    @discardableResult
    func regenerate() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return try replaceLocked()
    }

    /// Constant-time comparison of a presented bearer token against the current token.
    func isValid(_ presented: String?) -> Bool {
        lock.lock()
        let current = loadLocked()
        lock.unlock()
        guard let presented, let current else { return false }
        let lhs = Array(presented.utf8)
        let rhs = Array(current.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private func loadLocked() -> String? {
        if !hasLoaded {
            cachedToken = storage.readToken().flatMap { $0.isEmpty ? nil : $0 }
            hasLoaded = true
        }
        return cachedToken
    }

    private func replaceLocked() throws -> String {
        let token = try Self.makeToken()
        guard storage.writeToken(token) else {
            throw PhoneDictationTokenError.storageFailed
        }
        cachedToken = token
        hasLoaded = true
        return token
    }

    /// 32 random bytes, base64url without padding.
    static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PhoneDictationTokenError.randomGenerationFailed
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
