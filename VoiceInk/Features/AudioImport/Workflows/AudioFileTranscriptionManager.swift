import AVFoundation
import Foundation
import SwiftData
import SwiftUI
import os

@MainActor
class AudioTranscriptionManager: ObservableObject {
    static let shared = AudioTranscriptionManager()

    // MARK: - Published State

    @Published var queue: [AudioFileQueueItem] = []
    @Published var isProcessingQueue = false {
        didSet {
            // Keeps "Restart and Update" and the installer's quit request blocked.
            guard isProcessingQueue != oldValue else { return }
            if isProcessingQueue {
                FileTranscriptionActivity.shared.begin()
            } else {
                FileTranscriptionActivity.shared.end()
            }
        }
    }
    @Published var lastCompletedItemId: UUID?

    // MARK: - Private

    private var processingTask: Task<Void, Never>?
    private var processingGeneration: UInt64 = 0
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioTranscriptionManager")

    private init() {}

    // MARK: - Queue Management

    /// Add one or more audio file URLs to the queue. Invalid files are silently skipped.
    func addToQueue(urls: [URL]) {
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard SupportedMedia.isSupported(url: url) else { continue }

            // Avoid adding the same file path twice if it's already pending/processing
            let path = url.standardizedFileURL.path
            if queue.contains(where: { $0.url.standardizedFileURL.path == path && !$0.status.isTerminal }) {
                continue
            }

            let item = AudioFileQueueItem(url: url)
            queue.append(item)
        }
    }

    /// Remove a pending item from the queue.
    func removeFromQueue(id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let item = queue[index]

        // Only allow removing pending items
        guard case .pending = item.status else { return }

        queue.remove(at: index)
    }

    /// Clear all items from the queue, cancelling any in-progress work.
    func clearAll() {
        cancelProcessing()
        queue.removeAll()
        lastCompletedItemId = nil
    }

    /// Retry a failed item by resetting it to pending and re-enqueuing.
    func retryItem(id: UUID) {
        guard let item = queue.first(where: { $0.id == id }),
            case .failed = item.status
        else { return }

        item.status = .pending
    }

    /// Start processing pending items in the queue sequentially.
    func startProcessing(modelContext: ModelContext, engine: VoiceInkEngine, mode: ModeConfig) {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        processingGeneration &+= 1
        let generation = processingGeneration

        processingTask = Task { [weak self] in
            guard let self else { return }

            while let item = self.nextPendingItem() {
                guard !Task.isCancelled else { break }
                await self.processItem(item, modelContext: modelContext, engine: engine, mode: mode)
            }

            if self.processingGeneration == generation {
                self.isProcessingQueue = false
            }
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        isProcessingQueue = false

        // Reset any in-progress items back to pending
        for item in queue {
            if case .processing = item.status {
                item.status = .pending
            }
        }
    }

    var hasPendingItems: Bool {
        queue.contains {
            if case .pending = $0.status { return true }
            return false
        }
    }

    // MARK: - Private

    private func nextPendingItem() -> AudioFileQueueItem? {
        queue.first {
            if case .pending = $0.status { return true }
            return false
        }
    }

    private func processItem(
        _ item: AudioFileQueueItem, modelContext: ModelContext, engine: VoiceInkEngine, mode: ModeConfig
    ) async {
        let pipeline = AudioFileTranscriptionPipeline(modelContext: modelContext, engine: engine)

        let accessing = item.url.startAccessingSecurityScopedResource()
        defer { if accessing { item.url.stopAccessingSecurityScopedResource() } }

        do {
            let result = try await pipeline.transcribe(audioURL: item.url, mode: mode) { phase in
                switch phase {
                case .loading:
                    item.status = .processing(phase: .loading)
                case .processingAudio:
                    item.status = .processing(phase: .processingAudio)
                case .transcribing:
                    item.status = .processing(phase: .transcribing)
                case .enhancing:
                    item.status = .processing(phase: .enhancing)
                }
            }

            item.transcription = result.transcription
            item.status = .completed
            lastCompletedItemId = item.id

        } catch {
            if Task.isCancelled || error is CancellationError {
                item.status = .pending
            } else {
                logger.error("Transcription error: \(error, privacy: .public)")
                item.status = .failed(message: error.localizedDescription)
            }
        }
    }
}

enum TranscriptionError: Error, LocalizedError {
    case noModelSelected
    case transcriptionCancelled

    var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return String(localized: "No transcription model selected")
        case .transcriptionCancelled:
            return String(localized: "Transcription was cancelled")
        }
    }
}
