import Foundation
import SwiftData
import os

/// Owns the phone dictation server: the setting, its lifecycle, the pairing token and the addresses.
@MainActor
final class PhoneDictationController: ObservableObject {
    static let shared = PhoneDictationController()

    enum ServerState: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    static let enabledKey = "phoneDictationEnabled"
    static let portKey = "phoneDictationPort"
    static let defaultPort: UInt16 = 47821

    @Published private(set) var isEnabled: Bool
    @Published private(set) var serverState: ServerState = .stopped
    @Published private(set) var token: String?
    @Published private(set) var tokenError: String?
    @Published private(set) var addresses: [PhoneDictationAddress] = []

    private let defaults: UserDefaults
    private let tokenStore: PhoneDictationTokenStore
    private var server: PhoneDictationServer?
    private var startGeneration: UInt64 = 0
    private var pipeline: AudioFileTranscriptionPipeline?
    private var engine: VoiceInkEngine?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "PhoneDictation")

    init(
        defaults: UserDefaults = .standard,
        tokenStore: PhoneDictationTokenStore = PhoneDictationTokenStore(
            storage: KeychainPhoneDictationTokenStorage())
    ) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// The port the server uses; it is kept so that turning the option on again reuses it.
    var port: UInt16 {
        let stored = defaults.integer(forKey: Self.portKey)
        guard stored > 0, stored <= Int(UInt16.max) else { return Self.defaultPort }
        return UInt16(stored)
    }

    func configure(modelContext: ModelContext, engine: VoiceInkEngine) {
        self.engine = engine
        self.pipeline = AudioFileTranscriptionPipeline(modelContext: modelContext, engine: engine)
        if isEnabled {
            startServer()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            startServer()
        } else {
            stopServer()
        }
    }

    /// Stops the server when the app quits, keeping the setting for the next launch.
    func shutdown() {
        stopServer()
    }

    func regenerateToken() {
        do {
            token = try tokenStore.regenerate()
            tokenError = nil
        } catch {
            tokenError = error.localizedDescription
        }
    }

    func refreshAddresses() {
        addresses = PhoneDictationAddresses.current()
    }

    /// JSON encoded in the pairing QR code. See docs/phone-dictation-api.md.
    var pairingPayload: String? {
        guard let token, case .running(let port) = serverState else { return nil }
        let payload: [String: Any] = [
            "v": PhoneDictationAPI.version,
            "name": Host.current().localizedName ?? "Mac",
            "hosts": addresses.map(\.address),
            "port": Int(port),
            "token": token,
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    // MARK: - Server

    private func startServer() {
        guard pipeline != nil else { return }
        do {
            token = try tokenStore.currentToken()
            tokenError = nil
        } catch {
            tokenError = error.localizedDescription
            serverState = .failed(error.localizedDescription)
            return
        }
        refreshAddresses()

        server?.stop()
        let server = PhoneDictationServer(tokenStore: tokenStore, handlers: makeHandlers())
        server.onFailure = { [weak self, weak server] error in
            guard let self, let server, self.server === server else { return }
            self.serverState = .failed(error.localizedDescription)
        }
        self.server = server
        serverState = .starting
        startGeneration &+= 1
        let generation = startGeneration
        let port = self.port

        Task { @MainActor [weak self] in
            do {
                let boundPort = try await server.start(port: port)
                guard let self, self.startGeneration == generation, self.isEnabled else {
                    server.stop()
                    return
                }
                self.defaults.set(Int(boundPort), forKey: Self.portKey)
                self.serverState = .running(port: boundPort)
            } catch {
                guard let self, self.startGeneration == generation else { return }
                self.logger.error("Phone dictation server failed to start: \(error, privacy: .public)")
                self.server = nil
                self.serverState = .failed(error.localizedDescription)
            }
        }
    }

    private func stopServer() {
        startGeneration &+= 1
        server?.stop()
        server = nil
        serverState = .stopped
    }

    private func makeHandlers() -> PhoneDictationHandlers {
        PhoneDictationHandlers(
            readiness: { [weak self] in
                guard let configuration = self?.currentConfiguration() else { return .noModelSelected }
                return .ready(model: configuration.model.displayName, mode: configuration.mode.name)
            },
            transcribe: { [weak self] audioURL in
                guard let self, let pipeline = self.pipeline,
                    let mode = ModeManager.shared.currentEffectiveConfiguration
                else {
                    throw TranscriptionError.noModelSelected
                }
                FileTranscriptionActivity.shared.begin()
                defer { FileTranscriptionActivity.shared.end() }
                let result = try await pipeline.transcribe(audioURL: audioURL, mode: mode, source: .phone)
                return Self.responseBody(for: result)
            }
        )
    }

    private func currentConfiguration() -> TranscriptionRuntimeConfiguration? {
        guard let engine, let mode = ModeManager.shared.currentEffectiveConfiguration else { return nil }
        return ModeRuntimeResolver.transcriptionConfiguration(
            mode: mode, transcriptionModelManager: engine.transcriptionModelManager)
    }

    static func responseBody(for result: AudioFileTranscriptionResult) -> PhoneDictationTranscribeBody {
        let duration = result.transcription.duration
        return PhoneDictationTranscribeBody(
            id: result.transcription.id,
            text: result.finalText,
            durationSeconds: duration.isFinite ? duration : 0,
            model: result.transcription.transcriptionModelName,
            mode: result.transcription.modeName,
            enhancementError: result.enhancementFailure
        )
    }
}
