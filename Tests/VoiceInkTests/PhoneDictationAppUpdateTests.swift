import Foundation
import Testing
@testable import VoiceInk

private final class AppUpdateTokenStorage: PhoneDictationTokenStorage {
    var token: String?

    func readToken() -> String? { token }

    func writeToken(_ token: String) -> Bool {
        self.token = token
        return true
    }
}

private let apkBytes = Data((0..<70_000).map { UInt8(($0 * 7) % 256) })

private func appMetadata(
    applicationId: String = PhoneDictationAppUpdateSource.applicationId,
    versionCode: Int = 42,
    versionName: String = "0.1.42-abcdef123456"
) -> Data {
    let object: [String: Any] = [
        "applicationId": applicationId, "versionCode": versionCode, "versionName": versionName,
    ]
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// `GET /v1/app-update` and `GET /v1/app-update/apk`, through a running server whose APK folder
/// is a temporary directory (never the real app bundle).
@MainActor
@Suite(.serialized)
struct PhoneDictationAppUpdateTests {
    private struct Harness {
        let server: PhoneDictationServer
        let port: UInt16
        let token: String
        let directory: URL

        func get(_ path: String, token: String?) async throws -> (status: Int, data: Data, headers: [String: String]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.timeoutInterval = 10
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            let http = response as! HTTPURLResponse
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
            }
            return (http.statusCode, data, headers)
        }

        func cleanUp() {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// `apk` and `metadata` nil leave that file out.
    private func start(apk: Data? = apkBytes, metadata: Data? = appMetadata()) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let apk { try apk.write(to: directory.appendingPathComponent("VoiceInkKeyboard.apk")) }
        if let metadata { try metadata.write(to: directory.appendingPathComponent("VoiceInkKeyboard.json")) }

        let tokenStore = PhoneDictationTokenStore(storage: AppUpdateTokenStorage())
        let token = try tokenStore.currentToken()
        let server = PhoneDictationServer(
            tokenStore: tokenStore,
            handlers: PhoneDictationHandlers(
                readiness: { .ready(model: "Fake Model", mode: nil) },
                transcribe: { _ in throw CancellationError() }),
            appUpdate: PhoneDictationAppUpdateSource(directory: directory))
        let port = try await server.start(port: 0)
        return Harness(server: server, port: port, token: token, directory: directory)
    }

    private func errorCode(_ data: Data) throws -> PhoneDictationErrorCode {
        try JSONDecoder().decode(PhoneDictationErrorBody.self, from: data).error.code
    }

    @Test func metadataDescribesTheBundledAPK() async throws {
        let harness = try await start()
        defer { harness.cleanUp() }

        let response = try await harness.get("/v1/app-update", token: harness.token)

        #expect(response.status == 200)
        #expect(response.headers["content-type"] == "application/json; charset=utf-8")
        let body = try JSONDecoder().decode(PhoneDictationAppUpdateBody.self, from: response.data)
        #expect(body == PhoneDictationAppUpdateBody(
            versionCode: 42, versionName: "0.1.42-abcdef123456", size: apkBytes.count,
            sha256: PhoneDictationAppUpdateSource.sha256Hex(apkBytes)))
        #expect(body.sha256.count == 64)
    }

    @Test func downloadServesTheAPKBytes() async throws {
        let harness = try await start()
        defer { harness.cleanUp() }

        let response = try await harness.get("/v1/app-update/apk", token: harness.token)

        #expect(response.status == 200)
        #expect(response.data == apkBytes)
        #expect(response.headers["content-type"] == "application/vnd.android.package-archive")
        #expect(response.headers["content-length"] == String(apkBytes.count))
    }

    @Test func bothEndpointsRequireThePairingToken() async throws {
        let harness = try await start()
        defer { harness.cleanUp() }

        for path in ["/v1/app-update", "/v1/app-update/apk"] {
            for token in [nil, "wrong"] as [String?] {
                let response = try await harness.get(path, token: token)
                #expect(response.status == 401)
                #expect(try errorCode(response.data) == .unauthorized)
                #expect(response.data != apkBytes)
            }
        }
    }

    @Test func nothingIsServedWithoutABundledAPK() async throws {
        for (apk, metadata) in [(nil, appMetadata()), (apkBytes, nil), (Data(), appMetadata())] as [(Data?, Data?)] {
            let harness = try await start(apk: apk, metadata: metadata)
            defer { harness.cleanUp() }

            for path in ["/v1/app-update", "/v1/app-update/apk"] {
                let response = try await harness.get(path, token: harness.token)
                #expect(response.status == 404)
                #expect(try errorCode(response.data) == .appUpdateUnavailable)
            }
        }
    }

    @Test func invalidMetadataServesNothing() async throws {
        let invalid: [Data] = [
            Data("not json".utf8),
            Data(#"{"applicationId":"com.voiceink.keyboard","versionName":"0.1.1-x"}"#.utf8),
            Data(#"{"applicationId":"com.voiceink.keyboard","versionCode":"42","versionName":"0.1.42-x"}"#.utf8),
            appMetadata(versionCode: 0),
            appMetadata(versionName: " "),
            appMetadata(applicationId: "com.example.other"),
        ]
        for metadata in invalid {
            let harness = try await start(metadata: metadata)
            defer { harness.cleanUp() }

            for path in ["/v1/app-update", "/v1/app-update/apk"] {
                let response = try await harness.get(path, token: harness.token)
                #expect(response.status == 404)
                #expect(try errorCode(response.data) == .appUpdateUnavailable)
                #expect(response.data != apkBytes)
            }
        }
    }

    @Test func aMissingFolderServesNothingAndWrongMethodsAreRejected() async throws {
        let harness = try await start(apk: nil, metadata: nil)
        defer { harness.cleanUp() }
        try FileManager.default.removeItem(at: harness.directory)

        let missing = try await harness.get("/v1/app-update", token: harness.token)
        #expect(missing.status == 404)
        #expect(try errorCode(missing.data) == .appUpdateUnavailable)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(harness.port)/v1/app-update")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(harness.token)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        #expect((response as! HTTPURLResponse).statusCode == 405)
        #expect(try errorCode(data) == .methodNotAllowed)
    }

    @Test func aReplacedAPKIsHashedAgain() async throws {
        let harness = try await start()
        defer { harness.cleanUp() }
        let first = try await harness.get("/v1/app-update", token: harness.token)
        let firstBody = try JSONDecoder().decode(PhoneDictationAppUpdateBody.self, from: first.data)

        let replacement = Data(repeating: 9, count: 1234)
        try replacement.write(to: harness.directory.appendingPathComponent("VoiceInkKeyboard.apk"))

        let second = try await harness.get("/v1/app-update", token: harness.token)
        let secondBody = try JSONDecoder().decode(PhoneDictationAppUpdateBody.self, from: second.data)
        #expect(secondBody.size == 1234)
        #expect(secondBody.sha256 == PhoneDictationAppUpdateSource.sha256Hex(replacement))
        #expect(secondBody.sha256 != firstBody.sha256)
    }
}
