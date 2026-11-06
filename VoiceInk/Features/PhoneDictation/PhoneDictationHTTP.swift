import Foundation

/// Version 1 of the phone dictation API. See docs/phone-dictation-api.md.
enum PhoneDictationAPI {
    static let version = 1
    static let statusPath = "/v1/status"
    static let transcribePath = "/v1/transcribe"
    /// Largest accepted request body.
    static let maxBodyBytes = 64 * 1024 * 1024
    /// Largest accepted request line plus headers.
    static let maxHeadBytes = 16 * 1024

    /// Audio file extensions accepted for each `Content-Type`.
    static let contentTypeExtensions: [String: String] = [
        "audio/mp4": "m4a",
        "audio/m4a": "m4a",
        "audio/x-m4a": "m4a",
        "audio/mp4a-latm": "m4a",
        "audio/aac": "aac",
        "audio/aacp": "aac",
        "audio/x-aac": "aac",
        "audio/wav": "wav",
        "audio/wave": "wav",
        "audio/x-wav": "wav",
        "audio/vnd.wave": "wav",
        "audio/mpeg": "mp3",
        "audio/mp3": "mp3",
        "audio/aiff": "aiff",
        "audio/x-aiff": "aiff",
        "audio/flac": "flac",
        "audio/x-flac": "flac",
        "audio/x-caf": "caf",
        "audio/amr": "amr",
        "audio/ogg": "ogg",
        "audio/opus": "opus",
        "audio/3gpp": "3gp",
        "video/3gpp": "3gp",
        "video/mp4": "mp4",
        "video/quicktime": "mov",
    ]

    /// The file extension for an upload: an explicit `format` wins over `Content-Type`, and an
    /// unsupported `format` is rejected rather than ignored.
    static func audioFileExtension(contentType: String?, format: String?) -> String? {
        if let format = format?.lowercased() {
            return SupportedMedia.extensions.contains(format) ? format : nil
        }
        guard let contentType else { return nil }
        let mediaType = contentType.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return contentTypeExtensions[mediaType]
    }
}

/// Error codes returned to the phone in `{"error": {"code": …, "message": …}}`.
enum PhoneDictationErrorCode: String, Codable, Equatable {
    case unauthorized
    case noModelSelected = "no_model_selected"
    case transcriptionFailed = "transcription_failed"
    case payloadTooLarge = "payload_too_large"
    case lengthRequired = "length_required"
    case unsupportedMediaType = "unsupported_media_type"
    case badRequest = "bad_request"
    case notFound = "not_found"
    case methodNotAllowed = "method_not_allowed"

    var httpStatus: Int {
        switch self {
        case .unauthorized: return 401
        case .noModelSelected: return 503
        case .transcriptionFailed: return 500
        case .payloadTooLarge: return 413
        case .lengthRequired: return 411
        case .unsupportedMediaType: return 415
        case .badRequest: return 400
        case .notFound: return 404
        case .methodNotAllowed: return 405
        }
    }

    var defaultMessage: String {
        switch self {
        case .unauthorized: return "Missing or invalid pairing token."
        case .noModelSelected: return "No transcription model is selected on the Mac."
        case .transcriptionFailed: return "Transcription failed."
        case .payloadTooLarge: return "The audio upload is larger than \(PhoneDictationAPI.maxBodyBytes) bytes."
        case .lengthRequired: return "A Content-Length header is required."
        case .unsupportedMediaType: return "Unsupported audio format."
        case .badRequest: return "Malformed request."
        case .notFound: return "Unknown endpoint."
        case .methodNotAllowed: return "Method not allowed for this endpoint."
        }
    }
}

struct PhoneDictationErrorBody: Codable, Equatable {
    struct Detail: Codable, Equatable {
        let code: PhoneDictationErrorCode
        let message: String
    }
    let error: Detail
}

struct PhoneDictationStatusBody: Codable, Equatable {
    let apiVersion: Int
    let status: String
    let model: String
    let mode: String?
}

struct PhoneDictationTranscribeBody: Codable, Equatable {
    let id: UUID
    let text: String
    let durationSeconds: Double
    let model: String?
    let mode: String?
    let enhancementError: String?
}

struct PhoneDictationHTTPRequestHead: Equatable {
    let method: String
    let path: String
    let query: [String: String]
    /// Header names are lower-cased.
    let headers: [String: String]

    var contentLength: Int? {
        headers["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    var bearerToken: String? {
        guard let value = headers["authorization"] else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    /// Parses a request line and headers (without the terminating blank line).
    static func parse(_ data: Data) -> PhoneDictationHTTPRequestHead? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }

        guard let components = URLComponents(string: String(parts[1])) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        return PhoneDictationHTTPRequestHead(
            method: String(parts[0]).uppercased(),
            path: components.path,
            query: query,
            headers: headers
        )
    }
}

struct PhoneDictationHTTPResponse: Equatable {
    let status: Int
    let body: Data

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> PhoneDictationHTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return PhoneDictationHTTPResponse(status: status, body: body)
    }

    static func error(_ code: PhoneDictationErrorCode, message: String? = nil) -> PhoneDictationHTTPResponse {
        json(
            PhoneDictationErrorBody(error: .init(code: code, message: message ?? code.defaultMessage)),
            status: code.httpStatus
        )
    }

    /// The full HTTP/1.1 message; every response closes the connection.
    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        if status == 401 {
            head += "WWW-Authenticate: Bearer\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
