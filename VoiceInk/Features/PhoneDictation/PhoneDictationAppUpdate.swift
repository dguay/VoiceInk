import CryptoKit
import Foundation
import os

/// `GET /v1/app-update` on success.
struct PhoneDictationAppUpdateBody: Codable, Equatable {
    let versionCode: Int
    let versionName: String
    /// Size of the APK in bytes.
    let size: Int
    /// Lower-case hex SHA-256 of the APK.
    let sha256: String
}

/// The Android keyboard APK bundled in the Mac app, so the phone can update itself from the Mac it
/// is paired with. The APK always belongs to the installed Mac build (and follows its rollback).
///
/// The folder holds `VoiceInkKeyboard.apk` and `VoiceInkKeyboard.json`, the metadata that
/// `android/scripts/build-release.sh` writes next to the APK (`applicationId`, `versionCode`,
/// `versionName`). Size and SHA-256 are computed here, from the APK itself.
final class PhoneDictationAppUpdateSource: @unchecked Sendable {
    static let applicationId = "com.voiceink.keyboard"
    static let apkFileName = "VoiceInkKeyboard.apk"
    static let metadataFileName = "VoiceInkKeyboard.json"
    /// Anything larger is not an APK of this app.
    static let maxAPKBytes = 256 * 1024 * 1024

    /// `VoiceInk.app/Contents/Resources/AndroidKeyboard`.
    static var bundledDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("AndroidKeyboard", isDirectory: true)
    }

    enum Unavailable: Error, Equatable {
        case noDirectory
        case missingAPK
        case missingMetadata
        case invalidMetadata
        case otherApplication
        case unreadableAPK
    }

    private struct Metadata: Decodable {
        let applicationId: String
        let versionCode: Int
        let versionName: String
    }

    /// Identifies one version of the APK file, so its hash is computed once.
    private struct FileKey: Equatable {
        let size: Int
        let modified: Date?
        let inode: UInt64?
    }

    let directory: URL?
    private let lock = NSLock()
    private var cachedDigest: (key: FileKey, sha256: String)?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "PhoneDictation")

    /// `directory` defaults to the folder in the app bundle; tests pass a temporary folder.
    init(directory: URL? = PhoneDictationAppUpdateSource.bundledDirectory) {
        self.directory = directory
    }

    private var apkURL: URL? { directory?.appendingPathComponent(Self.apkFileName) }

    /// The bundled APK's version, size and SHA-256.
    func metadata() -> Result<PhoneDictationAppUpdateBody, Unavailable> {
        do {
            let metadata = try loadMetadata()
            let (key, apkURL) = try apkFile()
            let sha256: String
            if let cached = cachedSHA256(for: key) {
                sha256 = cached
            } else {
                guard let data = try? Data(contentsOf: apkURL, options: .mappedIfSafe), data.count == key.size else {
                    throw Unavailable.unreadableAPK
                }
                sha256 = Self.sha256Hex(data)
                store(sha256, for: key)
            }
            return .success(body(metadata, size: key.size, sha256: sha256))
        } catch {
            return .failure(unavailable(error))
        }
    }

    /// The APK bytes, with the metadata computed from those same bytes.
    func apk() -> Result<(body: PhoneDictationAppUpdateBody, data: Data), Unavailable> {
        do {
            let metadata = try loadMetadata()
            let (_, apkURL) = try apkFile()
            guard let data = try? Data(contentsOf: apkURL), !data.isEmpty, data.count <= Self.maxAPKBytes else {
                throw Unavailable.unreadableAPK
            }
            return .success((body(metadata, size: data.count, sha256: Self.sha256Hex(data)), data))
        } catch {
            return .failure(unavailable(error))
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func body(_ metadata: Metadata, size: Int, sha256: String) -> PhoneDictationAppUpdateBody {
        PhoneDictationAppUpdateBody(
            versionCode: metadata.versionCode, versionName: metadata.versionName, size: size, sha256: sha256)
    }

    private func loadMetadata() throws -> Metadata {
        guard let directory else { throw Unavailable.noDirectory }
        let url = directory.appendingPathComponent(Self.metadataFileName)
        guard let data = try? Data(contentsOf: url) else { throw Unavailable.missingMetadata }
        guard
            let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
            metadata.versionCode > 0,
            !metadata.versionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw Unavailable.invalidMetadata
        }
        guard metadata.applicationId == Self.applicationId else { throw Unavailable.otherApplication }
        return metadata
    }

    private func apkFile() throws -> (FileKey, URL) {
        guard let apkURL else { throw Unavailable.noDirectory }
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: apkURL.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = (attributes[.size] as? NSNumber)?.intValue
        else {
            throw Unavailable.missingAPK
        }
        guard size > 0, size <= Self.maxAPKBytes else { throw Unavailable.unreadableAPK }
        let key = FileKey(
            size: size,
            modified: attributes[.modificationDate] as? Date,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        return (key, apkURL)
    }

    private func cachedSHA256(for key: FileKey) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let cachedDigest, cachedDigest.key == key else { return nil }
        return cachedDigest.sha256
    }

    private func store(_ sha256: String, for key: FileKey) {
        lock.lock()
        cachedDigest = (key, sha256)
        lock.unlock()
    }

    private func unavailable(_ error: Error) -> Unavailable {
        let reason = error as? Unavailable ?? .unreadableAPK
        // Asked on every status check; most Mac builds have no APK, so keep it quiet.
        logger.debug("No Android keyboard update to offer: \(String(describing: reason), privacy: .public)")
        return reason
    }
}
