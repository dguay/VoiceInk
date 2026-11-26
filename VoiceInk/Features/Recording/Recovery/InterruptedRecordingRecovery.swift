import Darwin
import Foundation
import SwiftData
import os

/// Turns recordings interrupted by a crash, force-quit or forced restart into
/// recoverable History entries, and discards them on request.
@MainActor
struct InterruptedRecordingRecovery {
    let markerStore: ActiveRecordingMarkerStore
    let modelContext: ModelContext
    var isProcessRunning: (Int32) -> Bool = InterruptedRecordingRecovery.isProcessRunning

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecordingRecovery")

    init(
        markerStore: ActiveRecordingMarkerStore = .standard,
        modelContext: ModelContext,
        isProcessRunning: @escaping (Int32) -> Bool = InterruptedRecordingRecovery.isProcessRunning
    ) {
        self.markerStore = markerStore
        self.modelContext = modelContext
        self.isProcessRunning = isProcessRunning
    }

    /// Recovers every recording whose process exited while it was recording.
    /// Markers owned by a running VoiceInk process (such as a second build sharing
    /// the same data) are left alone.
    @discardableResult
    func recoverInterruptedRecordings() -> [Transcription] {
        var recovered: [Transcription] = []

        for entry in markerStore.entries() {
            guard let marker = entry.marker else {
                logger.error("Removing unreadable recording marker \(entry.url.lastPathComponent, privacy: .public)")
                markerStore.remove(markerAt: entry.url)
                continue
            }

            if marker.processID == ProcessInfo.processInfo.processIdentifier || isProcessRunning(marker.processID) {
                continue
            }

            if let transcription = recover(marker) {
                recovered.append(transcription)
            }
            markerStore.remove(markerAt: entry.url)
        }

        if !recovered.isEmpty {
            do {
                try modelContext.save()
            } catch {
                logger.error("Failed to save recovered recordings: \(error, privacy: .public)")
            }
            for transcription in recovered {
                NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
            }
        }

        return recovered
    }

    private func recover(_ marker: ActiveRecordingMarker) -> Transcription? {
        let audioURL = marker.audioURL
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            logger.notice("Interrupted recording has no audio file; nothing to recover")
            return nil
        }

        if hasHistoryEntry(for: audioURL) {
            return nil
        }

        let result: InterruptedWAVFinalizer.Result
        do {
            result = try InterruptedWAVFinalizer.finalize(audioURL)
        } catch {
            logger.error("Could not finalize interrupted recording: \(String(describing: error), privacy: .public)")
            return nil
        }

        guard result.dataByteCount > 0 else {
            try? FileManager.default.removeItem(at: audioURL)
            return nil
        }

        let transcription = Transcription(
            text: Transcription.recoveredTranscriptionText,
            duration: result.duration,
            audioFileURL: audioURL.absoluteString,
            transcriptionStatus: .recovered
        )
        transcription.timestamp = marker.startedAt
        modelContext.insert(transcription)
        logger.notice(
            "Recovered interrupted recording duration=\(result.duration, privacy: .public)s"
        )
        return transcription
    }

    private func hasHistoryEntry(for audioURL: URL) -> Bool {
        let audioFileURL: String? = audioURL.absoluteString
        var descriptor = FetchDescriptor<Transcription>(
            predicate: #Predicate { $0.audioFileURL == audioFileURL }
        )
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Removes a recovered recording's History entry and its audio file.
    static func discard(_ transcription: Transcription, in modelContext: ModelContext) throws {
        if let audioFileURL = transcription.audioFileURL,
            let url = URL(string: audioFileURL),
            FileManager.default.fileExists(atPath: url.path)
        {
            try FileManager.default.removeItem(at: url)
        }
        modelContext.delete(transcription)
        try modelContext.save()
        NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
    }

    nonisolated static func isProcessRunning(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        return kill(processID, 0) == 0 || errno == EPERM
    }
}

/// Tells the user, once per launch, that interrupted recordings were recovered.
enum RecoveredRecordingNotice {
    @MainActor
    static func show(count: Int) {
        let title = count == 1
            ? String(localized: "Recovered an interrupted recording. Open History to transcribe or discard it.")
            : String(
                format: String(localized: "Recovered %lld interrupted recordings. Open History to transcribe or discard them."),
                count
            )
        NotificationManager.shared.showNotification(
            title: title,
            type: .warning,
            duration: 10.0,
            actionButton: (String(localized: "Open History"), HistoryNavigator.openHistory)
        )
    }
}
