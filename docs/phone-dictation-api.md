# Phone dictation API (v1)

VoiceInk on the Mac can act as the dictation engine for a paired phone. The phone uploads a
recording and receives the finished text: the selected mode's transcription model, dictionary,
word replacements and AI cleanup, exactly as **Transcribe Audio** produces it. Every result is
also saved to the Mac's History, marked as coming from the phone.

The server only runs while **Settings → Phone Dictation → Allow Phone Dictation** is on. It stops
when the option is turned off or VoiceInk quits, and it uses the same port when it starts again.

## Pairing

Turning the option on shows a QR code. It encodes this JSON object (keys sorted):

```json
{
  "hosts": ["192.168.1.20", "100.101.102.103"],
  "name": "David's MacBook Pro",
  "port": 47821,
  "token": "3q2-7wL2…",
  "v": 1
}
```

| Field | Meaning |
|---|---|
| `v` | API version. This document describes version `1`. |
| `name` | The Mac's name, for display. |
| `hosts` | IPv4 addresses of the Mac: LAN addresses first, then Tailscale (`100.64.0.0/10`) addresses. Try them in order. |
| `port` | TCP port of the HTTP server (default `47821`). |
| `token` | Pairing token: 43 characters of base64url, sent as a bearer token. |

The token is stored in the Mac's Keychain and is not synced. **Regenerate** in Settings replaces
it; the old token is rejected from the next request on, so the phone must scan the new code.

Call `GET /v1/status` after scanning to confirm the pairing.

## Transport and authentication

- Plain HTTP/1.1 over IPv4 on `http://HOST:PORT`. Use it only on a trusted LAN or over Tailscale.
- Every request needs `Authorization: Bearer TOKEN`. A missing or wrong token gets `401`
  before the request body is read; no transcription runs.
- One request per connection; every response has `Connection: close`.
- Responses are `application/json; charset=utf-8`.

## `GET /v1/status`

Answers whether the token is valid and the Mac is ready to transcribe.

`200 OK`:

```json
{ "apiVersion": 1, "mode": "Default", "model": "Parakeet V3", "status": "ready" }
```

| Field | Type | Meaning |
|---|---|---|
| `apiVersion` | integer | Server API version. |
| `status` | string | Always `"ready"` on `200`. |
| `model` | string | Display name of the transcription model that will be used. |
| `mode` | string or null | Name of the mode whose settings apply. |

When no usable transcription model is selected for the current mode: `503` with
`no_model_selected` (see [Errors](#errors)).

## `POST /v1/transcribe`

Transcribes one recording and returns the final text.

Request:

- Body: the raw audio file bytes (not multipart).
- `Content-Length`: required. Chunked uploads get `411`.
- Maximum body size: 64 MiB (67 108 864 bytes). Larger uploads get `413` before the body is read.
- `Content-Type`: selects the audio format. Alternatively, pass `?format=EXT` with one of the
  extensions below; `format` wins over `Content-Type` (use it with `application/octet-stream`).

| Content-Type | Format |
|---|---|
| `audio/mp4`, `audio/m4a`, `audio/x-m4a`, `audio/mp4a-latm` | `m4a` (AAC in MP4, Android `MediaRecorder` `MPEG_4`/`AAC`) |
| `audio/aac`, `audio/aacp`, `audio/x-aac` | `aac` (ADTS) |
| `audio/wav`, `audio/wave`, `audio/x-wav`, `audio/vnd.wave` | `wav` |
| `audio/mpeg`, `audio/mp3` | `mp3` |
| `audio/aiff`, `audio/x-aiff` | `aiff` |
| `audio/flac`, `audio/x-flac` | `flac` |
| `audio/x-caf` | `caf` |
| `audio/amr` | `amr` |
| `audio/ogg` | `ogg` |
| `audio/opus` | `opus` |
| `audio/3gpp`, `video/3gpp` | `3gp` |
| `video/mp4` | `mp4` |
| `video/quicktime` | `mov` |

Accepted `format` values: `wav`, `mp3`, `m4a`, `aiff`, `mp4`, `mov`, `aac`, `flac`, `caf`,
`amr`, `ogg`, `oga`, `opus`, `3gp`. Any other `format` or type gets `415`.

Requests are processed one at a time, in the order their uploads complete; a request that
arrives while another is transcribing waits. Turning the option off drops waiting requests; a
transcription already running finishes and is saved to History. Set a generous read timeout (transcription and AI cleanup can take a while
for long recordings).

`200 OK`:

```json
{
  "durationSeconds": 4.2,
  "enhancementError": null,
  "id": "0F8B3B0C-5E43-4C1B-9B7A-2A2E8F9D1C11",
  "mode": "Default",
  "model": "Parakeet V3",
  "text": "Pick up milk on the way home."
}
```

| Field | Type | Meaning |
|---|---|---|
| `text` | string | The final text: the AI-cleaned text when AI cleanup ran and succeeded, otherwise the transcription after dictionary and word replacements. |
| `id` | string (UUID) | ID of the History entry on the Mac. |
| `durationSeconds` | number | Length of the recording. |
| `model` | string or null | Transcription model used. |
| `mode` | string or null | Mode whose settings were applied. |
| `enhancementError` | string or null | Why AI cleanup failed, when it was attempted and failed; `text` is then the un-cleaned text. |

Example:

```sh
curl -sS -X POST "http://192.168.1.20:47821/v1/transcribe" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: audio/mp4" \
  --data-binary @recording.m4a
```

## Errors

Every error has the same body:

```json
{ "error": { "code": "unauthorized", "message": "Missing or invalid pairing token." } }
```

`message` is human-readable and may change; branch on `code`.

| HTTP | `code` | When |
|---|---|---|
| 400 | `bad_request` | Malformed request, empty body or headers over 16 KiB. |
| 401 | `unauthorized` | Missing or wrong bearer token (including a token that was regenerated). Re-pair. |
| 404 | `not_found` | Unknown path. |
| 405 | `method_not_allowed` | Wrong method for the path. |
| 411 | `length_required` | `Content-Length` missing, or chunked transfer encoding. |
| 413 | `payload_too_large` | Body over 64 MiB. |
| 415 | `unsupported_media_type` | Audio format not recognised from `format` or `Content-Type`. |
| 500 | `transcription_failed` | The audio could not be decoded or transcribed; `message` gives the reason. |
| 503 | `no_model_selected` | No usable transcription model is selected for the current mode on the Mac. |

The server closes a connection that has not delivered a complete request within 5 minutes.
