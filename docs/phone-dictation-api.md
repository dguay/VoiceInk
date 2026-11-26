# Phone dictation API (v1)

VoiceInk on the Mac can act as the dictation engine for a paired phone. The phone uploads a
recording and receives the finished text: the transcription model, dictionary,
word replacements and AI cleanup of the mode chosen for the phone (see [Mode resolution](#mode-resolution)), as **Transcribe Audio** produces it. Every result is
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
| `mode` | string or null | Name of the mode a transcription without `app` would use (see [Mode resolution](#mode-resolution)). |

When no usable transcription model is selected for that mode: `503` with
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

Optional query parameters describe where the text goes. Both are additive in v1: a request
without them works as before.

| Parameter | Values | Meaning |
|---|---|---|
| `app` | Android package name, e.g. `com.whatsapp` | The app being typed into. Picks the mode (see [Mode resolution](#mode-resolution)) and is shown in the Mac's History next to the "From phone" mark. |
| `field` | `text`, `email`, `url`, `number`, `other` | The kind of field being typed into. |

Validation:

- `app` must look like an Android package name: at most 255 characters, dot-separated segments
  of ASCII letters, digits and underscores, each starting with a letter (`android` and
  `com.google.android.gm` are valid). Any other value (empty, too long, spaces, a leading digit,
  an empty segment) is ignored: the request runs and is saved as if it had no `app`. It never
  fails the request.
- `field` is case-insensitive. An unknown value (including an empty one) is treated as `other`.
  A missing `field` is treated like `text`.

`email`, `url` and `number` fields get the transcription after the output filter, dictionary
and word replacements, with no AI cleanup and no paragraph formatting, even when the mode turns
them on, so nothing rewrites what was spelled out. `text`, `other` and a missing `field` get the
mode's full processing.

The Android client derives `field` from the field's `inputType`: email address variations are
`email`, URI is `url`, number and phone classes are `number`, password and date/time fields are
`other`, every other text variation is `text`.

### Mode resolution

The phone, not the Mac, decides which mode applies. The Mac's own active mode (picked for its
frontmost app or website, or selected by hand) is never used for a phone request. The mode is:

1. an enabled mode with an Android app rule matching `app` (Android app rules are planned; until
   they exist this step never matches),
2. otherwise the enabled **Default** mode,
3. otherwise the first enabled mode.

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
| `text` | string | The final text: the AI-cleaned text when AI cleanup ran and succeeded, otherwise the transcription after dictionary and word replacements (always so for `email`, `url` and `number` fields). |
| `id` | string (UUID) | ID of the History entry on the Mac. |
| `durationSeconds` | number | Length of the recording. |
| `model` | string or null | Transcription model used. |
| `mode` | string or null | Mode whose settings were applied, resolved as in [Mode resolution](#mode-resolution). |
| `enhancementError` | string or null | Why AI cleanup failed, when it was attempted and failed; `text` is then the un-cleaned text. |

Example:

```sh
curl -sS -X POST "http://192.168.1.20:47821/v1/transcribe?app=com.google.android.gm&field=email" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: audio/mp4" \
  --data-binary @recording.m4a
```

## `POST /v1/corrections`

Lets Auto-Learn learn from a phone dictation corrected on the phone. The phone watches the field it
typed a dictation into and, when the user leaves it, sends what the field looked like right after
the dictation and when it was left. The Mac runs it through the same Auto-Learn pipeline as a
dictation pasted and corrected on the Mac (same correction diff, pending queue, review and
thresholds). While Auto-Learn is off the request is accepted and nothing is queued.

Request:

- `Content-Type: application/json`, `Content-Length` required (chunked uploads get `411`).
- Maximum body size: 256 KiB (262 144 bytes). Larger requests get `413` before the body is read.
- Not queued behind transcriptions; it is answered at once.

```json
{
  "id": "0F8B3B0C-5E43-4C1B-9B7A-2A2E8F9D1C11",
  "insertedText": "Dictate with Parakeat today",
  "insertStart": 6,
  "textAfterInsert": "Note: Dictate with Parakeat today",
  "textWhenLeft": "Note: Dictate with Parakeet today"
}
```

| Field | Type | Meaning |
|---|---|---|
| `id` | string (UUID) | The History `id` returned by `POST /v1/transcribe`. It must be a dictation from the phone. |
| `insertedText` | string | The dictated text as typed into the field (not empty, at most 12 000 UTF-16 code units). |
| `textAfterInsert` | string | A window of the field text right after the dictation was typed. |
| `textWhenLeft` | string | The same window of the field text when the user left the field. |
| `insertStart` | integer | Where `insertedText` starts in `textAfterInsert`, in UTF-16 code units. `textAfterInsert` must contain `insertedText` there. |

Each text is at most 32 000 UTF-16 code units. Send only a window around the dictation, never the
whole field: the Android client sends at most 200 characters before and 200 after it, cut at the
same place in both texts, and sends nothing when text outside the window changed.

`200 OK`:

```json
{ "autoLearnEnabled": true, "status": "accepted" }
```

| Field | Type | Meaning |
|---|---|---|
| `status` | string | Always `"accepted"` on `200`. |
| `autoLearnEnabled` | boolean | False when Auto-Learn is off on the Mac: the snapshot was dropped. |

A snapshot repeated for the same `id` (a retry after a lost response) is accepted again but
learned from only once. Other outcomes: `400 bad_request` for malformed JSON or fields that do not
fit together, `404 unknown_dictation` when no History entry has that `id`, and
`409 not_phone_dictation` when the entry was not dictated on the phone.

## Errors

Every error has the same body:

```json
{ "error": { "code": "unauthorized", "message": "Missing or invalid pairing token." } }
```

`message` is human-readable and may change; branch on `code`.

| HTTP | `code` | When |
|---|---|---|
| 400 | `bad_request` | Malformed request, empty body or headers over 16 KiB; for `/v1/corrections`, malformed JSON or inconsistent fields. |
| 401 | `unauthorized` | Missing or wrong bearer token (including a token that was regenerated). Re-pair. |
| 404 | `not_found` | Unknown path. |
| 404 | `unknown_dictation` | `/v1/corrections`: no History entry has this `id`. |
| 405 | `method_not_allowed` | Wrong method for the path. |
| 409 | `not_phone_dictation` | `/v1/corrections`: the History entry was not dictated on the phone. |
| 411 | `length_required` | `Content-Length` missing, or chunked transfer encoding. |
| 413 | `payload_too_large` | Body over 64 MiB (256 KiB for `/v1/corrections`). |
| 415 | `unsupported_media_type` | Audio format not recognised from `format` or `Content-Type`. |
| 500 | `transcription_failed` | The audio could not be decoded or transcribed; `message` gives the reason. |
| 503 | `no_model_selected` | No usable transcription model is selected for the phone's mode on the Mac. |

The server closes a connection that has not delivered a complete request within 5 minutes.
