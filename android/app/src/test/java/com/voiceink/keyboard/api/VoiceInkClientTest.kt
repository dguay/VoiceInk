package com.voiceink.keyboard.api

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.concurrent.atomic.AtomicInteger

/** Exercises the client against a local HTTP server that speaks docs/phone-dictation-api.md. */
class VoiceInkClientTest {
    @get:Rule val tmp = TemporaryFolder()

    private lateinit var server: HttpServer
    private val requests = AtomicInteger()
    private var handler: (HttpExchange) -> Unit = { respond(it, 404, """{"error":{"code":"not_found","message":"x"}}""") }

    private val client = VoiceInkClient(connectTimeoutMs = 2_000, statusReadTimeoutMs = 2_000, transcribeReadTimeoutMs = 2_000)

    @Before fun startServer() {
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
            requests.incrementAndGet()
            handler(exchange)
        }
        server.start()
    }

    @After fun stopServer() = server.stop(0)

    private fun pairing(hosts: List<String> = listOf("127.0.0.1"), token: String = "good-token") =
        Pairing("Mac", hosts, server.address.port, token)

    private fun audio(bytes: ByteArray = ByteArray(1234) { it.toByte() }): File =
        tmp.newFile("rec.m4a").apply { writeBytes(bytes) }

    @Test fun statusSuccessParsesModelAndMode() {
        var auth: String? = null
        var method: String? = null
        handler = {
            auth = it.requestHeaders.getFirst("Authorization")
            method = it.requestMethod
            respond(it, 200, """{"apiVersion":1,"mode":"Default","model":"Parakeet V3","status":"ready"}""")
        }

        val result = client.status(pairing())

        assertEquals(ApiResult.Success(MacStatus(1, "Parakeet V3", "Default"), "127.0.0.1"), result)
        assertEquals("Bearer good-token", auth)
        assertEquals("GET", method)
    }

    @Test fun statusAcceptsNullMode() {
        handler = { respond(it, 200, """{"apiVersion":1,"mode":null,"model":"Whisper","status":"ready"}""") }

        val result = client.status(pairing()) as ApiResult.Success

        assertNull(result.value.mode)
    }

    @Test fun transcribeUploadsRawAudioWithLengthAndType() {
        val bytes = ByteArray(5000) { (it % 251).toByte() }
        var received: ByteArray? = null
        var contentType: String? = null
        var contentLength: String? = null
        var path: String? = null
        handler = {
            path = it.requestURI.path
            contentType = it.requestHeaders.getFirst("Content-Type")
            contentLength = it.requestHeaders.getFirst("Content-Length")
            received = it.requestBody.readBytes()
            respond(
                it, 200,
                """{"durationSeconds":4.2,"enhancementError":null,"id":"0F8B3B0C-5E43-4C1B-9B7A-2A2E8F9D1C11",""" +
                    """"mode":"Default","model":"Parakeet V3","text":"Pick up milk on the way home."}""",
            )
        }

        val result = client.transcribe(pairing(), audio(bytes))

        assertEquals(
            ApiResult.Success(
                Transcription("Pick up milk on the way home.", "0F8B3B0C-5E43-4C1B-9B7A-2A2E8F9D1C11", 4.2, "Parakeet V3", "Default", null),
                "127.0.0.1",
            ),
            result,
        )
        assertEquals("/v1/transcribe", path)
        assertEquals("audio/mp4", contentType)
        assertEquals("5000", contentLength)
        assertTrue(bytes.contentEquals(received))
    }

    @Test fun transcribeKeepsEnhancementError() {
        handler = { respond(it, 200, """{"text":"raw text","enhancementError":"AI provider timed out","id":null,"durationSeconds":null,"model":null,"mode":null}""") }

        val value = (client.transcribe(pairing(), audio()) as ApiResult.Success).value

        assertEquals("raw text", value.text)
        assertEquals("AI provider timed out", value.enhancementError)
        assertNull(value.durationSeconds)
    }

    @Test fun unauthorizedIsReportedAsRejectedToken() {
        handler = { respond(it, 401, """{"error":{"code":"unauthorized","message":"Missing or invalid pairing token."}}""") }

        assertEquals(ApiResult.Failure(ApiError.Unauthorized), client.status(pairing(token = "wrong")))
        assertEquals(ApiResult.Failure(ApiError.Unauthorized), client.transcribe(pairing(token = "wrong"), audio()))
    }

    @Test fun noModelSelectedIsDistinct() {
        handler = { respond(it, 503, """{"error":{"code":"no_model_selected","message":"Select a model."}}""") }

        assertEquals(ApiResult.Failure(ApiError.NoModelSelected("Select a model.")), client.status(pairing()))
    }

    @Test fun transcriptionFailureCarriesMessage() {
        handler = { respond(it, 500, """{"error":{"code":"transcription_failed","message":"Audio could not be decoded."}}""") }

        assertEquals(
            ApiResult.Failure(ApiError.TranscriptionFailed("Audio could not be decoded.")),
            client.transcribe(pairing(), audio()),
        )
    }

    @Test fun otherDocumentedErrorsKeepStatusAndCode() {
        handler = { respond(it, 415, """{"error":{"code":"unsupported_media_type","message":"Nope."}}""") }

        assertEquals(
            ApiResult.Failure(ApiError.Server(415, "unsupported_media_type", "Nope.")),
            client.transcribe(pairing(), audio()),
        )
    }

    @Test fun errorMappingBranchesOnCodeNotStatus() {
        assertEquals(ApiError.Unauthorized, VoiceInkClient.mapError(401, ""))
        assertEquals(ApiError.Unauthorized, VoiceInkClient.mapError(401, "<html>"))
        assertEquals(ApiError.Server(503, null, null), VoiceInkClient.mapError(503, "Service Unavailable"))
        assertEquals(ApiError.NoModelSelected(null), VoiceInkClient.mapError(503, """{"error":{"code":"no_model_selected"}}"""))
        assertEquals(ApiError.Server(413, "payload_too_large", "Too big"), VoiceInkClient.mapError(413, """{"error":{"code":"payload_too_large","message":"Too big"}}"""))
        assertEquals(ApiError.Server(500, null, null), VoiceInkClient.mapError(500, """{"error":"oops"}"""))
    }

    @Test fun successWithBodyOutsideContractIsInvalidResponse() {
        handler = { respond(it, 200, "not json") }
        assertTrue((client.status(pairing()) as ApiResult.Failure).error is ApiError.InvalidResponse)

        handler = { respond(it, 200, """{"id":"x"}""") }
        assertTrue((client.transcribe(pairing(), audio()) as ApiResult.Failure).error is ApiError.InvalidResponse)

        handler = { respond(it, 200, """{"status":"busy","model":"x"}""") }
        assertTrue((client.status(pairing()) as ApiResult.Failure).error is ApiError.InvalidResponse)
    }

    @Test fun nothingListeningIsUnreachable() {
        val pairing = Pairing("Mac", listOf("127.0.0.1"), closedPort(), "t")

        assertEquals(ApiResult.Failure(ApiError.Unreachable), client.status(pairing))
        assertEquals(ApiResult.Failure(ApiError.Unreachable), client.transcribe(pairing, audio()))
    }

    @Test fun fallsBackToNextHostWhenAHostCannotBeReached() {
        handler = { respond(it, 200, """{"text":"hi"}""") }

        val result = client.transcribe(pairing(hosts = listOf("unreachable.invalid", "127.0.0.1")), audio())

        assertEquals("127.0.0.1", (result as ApiResult.Success).host)
        assertEquals(1, requests.get())
    }

    @Test fun preferredHostIsTriedFirst() {
        assertEquals(listOf("b", "a", "c"), VoiceInkClient.orderedHosts(listOf("a", "b", "c"), "b"))
        assertEquals(listOf("a", "b"), VoiceInkClient.orderedHosts(listOf("a", "b"), "gone"))
    }

    @Test fun connectionDroppedAfterConnectIsUnreachableAndNotResent() {
        // Both hosts reach the same server; a re-send to the second host would be counted.
        val raw = ServerSocket(0)
        val accepted = AtomicInteger()
        val acceptor = Thread {
            while (!raw.isClosed) {
                try {
                    raw.accept().use { socket ->
                        accepted.incrementAndGet()
                        socket.getInputStream().read(ByteArray(64))
                    }
                } catch (_: Exception) {
                    break
                }
            }
        }.apply { isDaemon = true; start() }

        val result = client.transcribe(Pairing("Mac", listOf("127.0.0.1", "localhost"), raw.localPort, "t"), audio(ByteArray(64)))

        raw.close()
        acceptor.join(1_000)
        assertEquals(ApiResult.Failure(ApiError.Unreachable), result)
        assertEquals(1, accepted.get())
    }

    private fun closedPort(): Int = ServerSocket(0).use { it.localPort }

    private fun respond(exchange: HttpExchange, status: Int, body: String) {
        exchange.requestBody.readBytes()
        val bytes = body.toByteArray()
        exchange.responseHeaders.add("Content-Type", "application/json; charset=utf-8")
        exchange.sendResponseHeaders(status, bytes.size.toLong())
        exchange.responseBody.use { it.write(bytes) }
    }
}
