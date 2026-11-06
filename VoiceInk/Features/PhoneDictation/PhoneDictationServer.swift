import Foundation
import Network
import os

enum PhoneDictationReadiness: Equatable {
    case ready(model: String, mode: String?)
    case noModelSelected
}

/// What the server needs from the app. Both closures run on the main actor.
struct PhoneDictationHandlers {
    var readiness: @MainActor () -> PhoneDictationReadiness
    /// Transcribes one uploaded file through the shared pipeline. The file is deleted afterwards.
    var transcribe: @MainActor (URL) async throws -> PhoneDictationTranscribeBody
}

/// Routes parsed requests. Authorization and size checks happen on the head alone, so a rejected
/// request never has its body read and never reaches the pipeline.
final class PhoneDictationRouter: @unchecked Sendable {
    enum HeadDecision: Equatable {
        case respond(PhoneDictationHTTPResponse)
        case respondAfterBody(length: Int)
        case readBody(length: Int, fileExtension: String)
    }

    private let tokenStore: PhoneDictationTokenStore
    private let handlers: PhoneDictationHandlers
    private let maxBodyBytes: Int
    private let queue: PhoneDictationSerialQueue
    private let lock = NSLock()
    /// Bumped on every stop, so requests admitted before a stop never start afterwards.
    private var generation: UInt64 = 0
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "PhoneDictation")

    init(
        tokenStore: PhoneDictationTokenStore,
        handlers: PhoneDictationHandlers,
        maxBodyBytes: Int,
        queue: PhoneDictationSerialQueue = PhoneDictationSerialQueue()
    ) {
        self.tokenStore = tokenStore
        self.handlers = handlers
        self.maxBodyBytes = maxBodyBytes
        self.queue = queue
    }

    /// Drops requests that are queued but not yet transcribing.
    func cancelPendingRequests() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    private var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func decide(_ head: PhoneDictationHTTPRequestHead) -> HeadDecision {
        switch head.path {
        case PhoneDictationAPI.statusPath:
            guard head.method == "GET" else { return .respond(.error(.methodNotAllowed)) }
            guard tokenStore.isValid(head.bearerToken) else { return .respond(.error(.unauthorized)) }
            return .respondAfterBody(length: 0)
        case PhoneDictationAPI.transcribePath:
            guard head.method == "POST" else { return .respond(.error(.methodNotAllowed)) }
            guard tokenStore.isValid(head.bearerToken) else { return .respond(.error(.unauthorized)) }
            if let transferEncoding = head.headers["transfer-encoding"],
                transferEncoding.lowercased() != "identity"
            {
                return .respond(.error(.lengthRequired))
            }
            guard let length = head.contentLength else { return .respond(.error(.lengthRequired)) }
            guard length <= maxBodyBytes else { return .respond(.error(.payloadTooLarge)) }
            guard length > 0 else { return .respond(.error(.badRequest, message: "The request has no audio.")) }
            guard
                let fileExtension = PhoneDictationAPI.audioFileExtension(
                    contentType: head.headers["content-type"], format: head.query["format"])
            else {
                return .respond(.error(.unsupportedMediaType))
            }
            return .readBody(length: length, fileExtension: fileExtension)
        default:
            return .respond(.error(.notFound))
        }
    }

    /// Answers a request whose head `decide` accepted.
    func respond(to head: PhoneDictationHTTPRequestHead, body: Data, fileExtension: String?) async
        -> PhoneDictationHTTPResponse
    {
        // A token regenerated while the upload was in flight is already invalid.
        guard tokenStore.isValid(head.bearerToken) else { return .error(.unauthorized) }

        guard head.path == PhoneDictationAPI.transcribePath, let fileExtension else {
            return await status()
        }
        let admitted = currentGeneration
        return await queue.run { [self] in
            guard currentGeneration == admitted else {
                return .error(.transcriptionFailed, message: "Phone dictation was turned off.")
            }
            return await transcribe(token: head.bearerToken, body: body, fileExtension: fileExtension)
        }
    }

    @MainActor
    private func status() -> PhoneDictationHTTPResponse {
        switch handlers.readiness() {
        case .ready(let model, let mode):
            return .json(
                PhoneDictationStatusBody(
                    apiVersion: PhoneDictationAPI.version, status: "ready", model: model, mode: mode))
        case .noModelSelected:
            return .error(.noModelSelected)
        }
    }

    @MainActor
    private func transcribe(token: String?, body: Data, fileExtension: String) async -> PhoneDictationHTTPResponse {
        // Queued requests are re-checked when their turn comes.
        guard tokenStore.isValid(token) else { return .error(.unauthorized) }
        if case .noModelSelected = handlers.readiness() {
            return .error(.noModelSelected)
        }

        let uploadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-dictation-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        defer { try? FileManager.default.removeItem(at: uploadURL) }

        do {
            try body.write(to: uploadURL, options: .atomic)
            let result = try await handlers.transcribe(uploadURL)
            return .json(result)
        } catch TranscriptionError.noModelSelected {
            return .error(.noModelSelected)
        } catch {
            logger.error("Phone dictation failed: \(error, privacy: .public)")
            return .error(.transcriptionFailed, message: error.localizedDescription)
        }
    }
}

/// Runs operations one at a time, in the order they were submitted. One queue is shared by every
/// server instance, so turning the option off and on never lets two transcriptions overlap.
@MainActor
final class PhoneDictationSerialQueue {
    private var tail: Task<Void, Never>?

    nonisolated init() {}

    func run(_ operation: @escaping @MainActor () async -> PhoneDictationHTTPResponse) async
        -> PhoneDictationHTTPResponse
    {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        tail = Task { @MainActor in _ = await task.value }
        return await task.value
    }
}

/// A minimal HTTP/1.1 server for the phone dictation API: one request per connection.
final class PhoneDictationServer: @unchecked Sendable {
    enum ServerError: Error, LocalizedError {
        case invalidPort

        var errorDescription: String? { String(localized: "The phone dictation port is invalid.") }
    }

    /// Called on the main actor when a running listener fails.
    var onFailure: (@MainActor (Error) -> Void)?

    private let router: PhoneDictationRouter
    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.phone-dictation")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: PhoneDictationConnection] = [:]
    private let requestTimeout: TimeInterval

    init(
        tokenStore: PhoneDictationTokenStore,
        handlers: PhoneDictationHandlers,
        maxBodyBytes: Int = PhoneDictationAPI.maxBodyBytes,
        requestTimeout: TimeInterval = 300,
        queue: PhoneDictationSerialQueue = PhoneDictationSerialQueue()
    ) {
        self.router = PhoneDictationRouter(
            tokenStore: tokenStore, handlers: handlers, maxBodyBytes: maxBodyBytes, queue: queue)
        self.requestTimeout = requestTimeout
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener != nil
    }

    /// Starts listening on all IPv4 interfaces. Port 0 picks a free port. Returns the bound port.
    func start(port: UInt16) async throws -> UInt16 {
        stop()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // IPv4 only: the pairing code advertises IPv4 addresses, and a dual-stack listener never
        // completes handshakes that arrive over Tailscale's tunnel interface.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let endpointPort: NWEndpoint.Port
        if port == 0 {
            endpointPort = .any
        } else {
            guard let fixed = NWEndpoint.Port(rawValue: port) else { throw ServerError.invalidPort }
            endpointPort = fixed
        }
        let listener = try NWListener(using: parameters, on: endpointPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        install(listener)

        return try await withCheckedThrowingContinuation { continuation in
            // State updates arrive serially on `queue`.
            let once = ResumeOnce(continuation)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    once.resume(returning: listener?.port?.rawValue ?? port)
                case .failed(let error), .waiting(let error):
                    listener?.cancel()
                    self?.forget(listener)
                    if !once.resume(throwing: error), let onFailure = self?.onFailure {
                        Task { @MainActor in onFailure(error) }
                    }
                case .cancelled:
                    once.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Stops listening, drops open connections and queued requests. A transcription that is
    /// already running finishes (and is saved to History). Safe to call when stopped.
    func stop() {
        router.cancelPendingRequests()
        lock.lock()
        let listener = self.listener
        self.listener = nil
        let open = Array(connections.values)
        connections.removeAll()
        lock.unlock()

        listener?.cancel()
        open.forEach { $0.cancel() }
    }

    private func install(_ listener: NWListener) {
        lock.lock()
        self.listener = listener
        lock.unlock()
    }

    private func forget(_ listener: NWListener?) {
        lock.lock()
        if let listener, self.listener === listener {
            self.listener = nil
        }
        lock.unlock()
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = PhoneDictationConnection(
            connection: nwConnection,
            router: router,
            queue: queue,
            requestTimeout: requestTimeout
        )
        let id = ObjectIdentifier(connection)
        lock.lock()
        let accepting = listener != nil
        if accepting {
            connections[id] = connection
        }
        lock.unlock()

        guard accepting else {
            nwConnection.cancel()
            return
        }
        connection.onClose = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.connections[id] = nil
            self.lock.unlock()
        }
        connection.start()
    }
}

/// Resumes a continuation at most once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?

    init(_ continuation: CheckedContinuation<UInt16, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: UInt16) -> Bool {
        take()?.resume(returning: value) != nil
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        take()?.resume(throwing: error) != nil
    }

    private func take() -> CheckedContinuation<UInt16, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }
}

/// One HTTP exchange. All state is touched on the server's queue.
final class PhoneDictationConnection: @unchecked Sendable {
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private let router: PhoneDictationRouter
    private let queue: DispatchQueue
    private let requestTimeout: TimeInterval
    private var buffer = Data()
    private var timeout: DispatchWorkItem?
    private var isClosed = false

    private static let headTerminator = Data("\r\n\r\n".utf8)
    private static let readChunk = 1024 * 1024

    init(connection: NWConnection, router: PhoneDictationRouter, queue: DispatchQueue, requestTimeout: TimeInterval) {
        self.connection = connection
        self.router = router
        self.queue = queue
        self.requestTimeout = requestTimeout
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        let timeout = DispatchWorkItem { [weak self] in self?.close() }
        self.timeout = timeout
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)
        connection.start(queue: queue)
        receiveHead()
    }

    func cancel() {
        // Strong capture: the server has already released this connection.
        queue.async { self.close() }
    }

    private func receiveHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data { self.buffer.append(data) }

            if let range = self.buffer.range(of: Self.headTerminator) {
                guard range.lowerBound - self.buffer.startIndex <= PhoneDictationAPI.maxHeadBytes else {
                    self.send(.error(.badRequest, message: "Request headers are too large."))
                    return
                }
                let headData = self.buffer.subdata(in: self.buffer.startIndex..<range.lowerBound)
                let rest = self.buffer.subdata(in: range.upperBound..<self.buffer.endIndex)
                self.buffer = Data()
                self.handleHead(headData, rest: rest)
            } else if self.buffer.count > PhoneDictationAPI.maxHeadBytes {
                self.send(.error(.badRequest, message: "Request headers are too large."))
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.receiveHead()
            }
        }
    }

    private func handleHead(_ headData: Data, rest: Data) {
        guard let head = PhoneDictationHTTPRequestHead.parse(headData) else {
            send(.error(.badRequest))
            return
        }

        switch router.decide(head) {
        case .respond(let response):
            send(response)
        case .respondAfterBody:
            dispatch(head: head, body: Data(), fileExtension: nil)
        case .readBody(let length, let fileExtension):
            if rest.count < length,
                head.headers["expect"]?.lowercased() == "100-continue"
            {
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
            }
            buffer = rest
            receiveBody(head: head, length: length, fileExtension: fileExtension)
        }
    }

    private func receiveBody(head: PhoneDictationHTTPRequestHead, length: Int, fileExtension: String) {
        if buffer.count >= length {
            let body = buffer.prefix(length)
            buffer = Data()
            dispatch(head: head, body: Data(body), fileExtension: fileExtension)
            return
        }
        let remaining = length - buffer.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, Self.readChunk)) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data { self.buffer.append(data) }
            if self.buffer.count >= length {
                self.receiveBody(head: head, length: length, fileExtension: fileExtension)
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.receiveBody(head: head, length: length, fileExtension: fileExtension)
            }
        }
    }

    private func dispatch(head: PhoneDictationHTTPRequestHead, body: Data, fileExtension: String?) {
        // The request is complete; processing time is not bounded by the upload timeout.
        timeout?.cancel()
        timeout = nil
        let router = router
        Task { [weak self] in
            let response = await router.respond(to: head, body: body, fileExtension: fileExtension)
            self?.queue.async { self?.send(response) }
        }
    }

    private func send(_ response: PhoneDictationHTTPResponse) {
        guard !isClosed else { return }
        connection.send(
            content: response.serialized(),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                self?.close()
            }
        )
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        timeout?.cancel()
        timeout = nil
        connection.cancel()
        onClose?()
        onClose = nil
    }
}
