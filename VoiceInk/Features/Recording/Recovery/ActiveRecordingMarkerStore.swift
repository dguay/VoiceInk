import Foundation
import os

/// Written beside an in-progress recording so a later launch can tell that the
/// process exited before the recording stopped.
struct ActiveRecordingMarker: Codable, Equatable {
    let audioFilePath: String
    let startedAt: Date
    let processID: Int32
    /// Distinguishes the owner from a later process that reuses `processID`.
    var bootSessionID: String? = nil
    var processStartTime: TimeInterval? = nil

    var audioURL: URL { URL(fileURLWithPath: audioFilePath) }
}

/// Persists one marker file per in-progress Mac recording.
///
/// A marker exists from the moment the hardware starts writing a recording until
/// the recording stops or is cancelled. A marker that survives its process is an
/// interrupted recording.
final class ActiveRecordingMarkerStore: @unchecked Sendable {
    struct Entry {
        let url: URL
        /// `nil` when the marker file is unreadable.
        let marker: ActiveRecordingMarker?
    }

    static let standard = ActiveRecordingMarkerStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("ActiveRecordings")
    )

    let directory: URL
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecordingRecovery")

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    func markerURL(for audioURL: URL) -> URL {
        directory
            .appendingPathComponent(audioURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("json")
    }

    func begin(
        audioURL: URL,
        startedAt: Date = Date(),
        processID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = ActiveRecordingMarker(
            audioFilePath: audioURL.path,
            startedAt: startedAt,
            processID: processID,
            bootSessionID: RecordingProcessIdentity.currentBootSessionID,
            processStartTime: RecordingProcessIdentity.startTime(of: processID)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: markerURL(for: audioURL), options: .atomic)
    }

    func end(audioURL: URL) {
        remove(markerAt: markerURL(for: audioURL))
    }

    func remove(markerAt url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            logger.error("Failed to remove recording marker: \(error, privacy: .public)")
        }
    }

    func entries() -> [Entry] {
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let marker = (try? Data(contentsOf: url)).flatMap {
                    try? decoder.decode(ActiveRecordingMarker.self, from: $0)
                }
                return Entry(url: url, marker: marker)
            }
    }
}

/// Keeps the marker of the recording the recorder is currently writing.
/// Every stop, including a cancel, clears it.
@MainActor
final class ActiveRecordingSessionTracker {
    private let store: ActiveRecordingMarkerStore
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecordingRecovery")
    private(set) var activeAudioURL: URL?

    nonisolated init(store: ActiveRecordingMarkerStore = .standard) {
        self.store = store
    }

    func recordingDidStart(audioURL: URL, startedAt: Date = Date()) {
        if let activeAudioURL, activeAudioURL != audioURL {
            store.end(audioURL: activeAudioURL)
        }
        activeAudioURL = audioURL
        do {
            try store.begin(audioURL: audioURL, startedAt: startedAt)
        } catch {
            // Recording continues; only crash recovery is unavailable for it.
            logger.error("Failed to write recording marker: \(error, privacy: .public)")
        }
    }

    func recordingDidStop() {
        guard let activeAudioURL else { return }
        store.end(audioURL: activeAudioURL)
        self.activeAudioURL = nil
    }
}
