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
    var isRecordingOwnerRunning: (ActiveRecordingMarker) -> Bool

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecordingRecovery")

    init(
        markerStore: ActiveRecordingMarkerStore = .standard,
        modelContext: ModelContext,
        isRecordingOwnerRunning: @escaping (ActiveRecordingMarker) -> Bool = RecordingProcessIdentity.isRunning
    ) {
        self.markerStore = markerStore
        self.modelContext = modelContext
        self.isRecordingOwnerRunning = isRecordingOwnerRunning
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

            if isRecordingOwnerRunning(marker) {
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
        let audioURL = transcription.audioFileURL.flatMap(URL.init(string:))
        // Save first so a failed save never leaves an entry whose audio is gone.
        modelContext.delete(transcription)
        try modelContext.save()
        if let audioURL, FileManager.default.fileExists(atPath: audioURL.path) {
            try? FileManager.default.removeItem(at: audioURL)
        }
        NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
    }

}

/// Identifies the process that owns a recording well enough to survive process ID reuse,
/// which is common right after a forced restart.
enum RecordingProcessIdentity {
    static var currentBootSessionID: String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Start time of a running process in seconds since 1970, or `nil` when no such process runs.
    static func startTime(of processID: Int32) -> TimeInterval? {
        guard processID > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
    }

    /// True only while the very process that wrote `marker` is still running.
    static func isRunning(_ marker: ActiveRecordingMarker) -> Bool {
        isRunning(
            marker,
            bootSessionID: currentBootSessionID,
            startTimeOfProcess: startTime(of:)
        )
    }

    static func isRunning(
        _ marker: ActiveRecordingMarker,
        bootSessionID: String?,
        startTimeOfProcess: (Int32) -> TimeInterval?
    ) -> Bool {
        // A different boot means every process of the old one is gone.
        if let markerBoot = marker.bootSessionID, let bootSessionID, markerBoot != bootSessionID {
            return false
        }
        guard let liveStart = startTimeOfProcess(marker.processID) else { return false }
        // The same ID with another start time is an unrelated process that reused it.
        guard let markerStart = marker.processStartTime else { return true }
        return abs(liveStart - markerStart) < 0.001
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
