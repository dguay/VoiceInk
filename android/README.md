# VoiceInk Keyboard for Android

A voice-only Android keyboard that dictates into any app through VoiceInk on your Mac, then
hands control back to your usual keyboard (SwiftKey, Samsung Keyboard, Gboard…).

- **Pairing**: scan the QR code from VoiceInk → Settings → Phone Dictation, or type the Mac's
  address, port and token. The app checks the pairing with `GET /v1/status` and keeps the token
  encrypted with an Android Keystore key that never leaves the phone.
- **Keyboard**: one large mic button and a status line. Switching to the keyboard starts
  recording right away; tap once to stop. (It waits for a tap instead when a kept recording is
  waiting for Retry, or when pairing or the microphone permission is missing.) The
  recording (AAC in MP4) goes to the Mac's `POST /v1/transcribe`; the text comes back through
  VoiceInk's pipeline (model, dictionary, word replacements, AI cleanup) and is inserted at the
  cursor. The keyboard then switches back to the previous one. The keyboard icon at the top left
  switches back without dictating.
- **Failures**: "Mac unreachable", "Token rejected", "No model selected on the Mac" and
  "Transcription failed" are shown on the keyboard. The recording is kept until its text is
  inserted, so **Retry** sends it again once the Mac is back; **Discard** drops it.

The API is described in [`docs/phone-dictation-api.md`](../docs/phone-dictation-api.md).
Requires Android 10 (API 29) or later.

## Build

Requirements: JDK 17+ and the Android SDK (platform 36). Point Gradle at the SDK with
`ANDROID_HOME` or a `local.properties` file containing `sdk.dir=/path/to/Android/sdk`.

```sh
cd android
./gradlew assembleDebug          # app/build/outputs/apk/debug/app-debug.apk
./gradlew testDebugUnitTest      # API client and pairing parser tests
./gradlew lintDebug
```

## Install on your phone

1. **Enable USB debugging** on the phone: Settings → About phone → tap *Build number* seven
   times, then Settings → System → Developer options → *USB debugging* (Samsung: Settings →
   Developer options). Connect the phone by USB and accept the prompt.
2. **Install**:

   ```sh
   adb devices                       # the phone must be listed as "device"
   adb install -r android/app/build/outputs/apk/debug/app-debug.apk
   ```

   Wireless alternative (Android 11+): Developer options → *Wireless debugging* → *Pair device
   with pairing code*, then `adb pair IP:PORT` and `adb connect IP:PORT`.
3. **On the Mac**: VoiceInk → Settings → Phone Dictation → turn on *Allow Phone Dictation*, and
   make sure a transcription model is selected.
4. **Open VoiceInk Keyboard** on the phone and follow the four steps:
   1. *Pair*: tap **Scan QR code** and scan the code on the Mac, or type the address shown under
      the code (LAN address, or the `100.x.y.z` Tailscale address when away from home), the port
      and the token (**Copy** on the Mac). The phone must be on the same network as the Mac or on
      the same Tailscale tailnet.
   2. *Allow the microphone*.
   3. *Turn on the keyboard*: **Open keyboard settings**, turn on **VoiceInk voice** and accept the
      system warning. Keep SwiftKey as the default keyboard.
   4. *Switch to it while typing* (below).

### Switching to the VoiceInk keyboard

- **Navigation-bar keyboard button** (the most reliable way):
  - Pixel / stock Android: the keyboard-switcher button appears at the bottom right of the
    navigation bar while a keyboard is open, as soon as more than one keyboard is turned on.
  - Samsung (One UI): Settings → General management → *Keyboard list and default* → turn on
    **Keyboard button on navigation bar**.

  Tap the button while any keyboard is open and choose **VoiceInk voice**.
- **SwiftKey**: long-press the space bar to open the keyboard picker, or use the globe key if
  you enabled it.
- **Gboard / Samsung Keyboard**: long-press the space bar or the globe key.

After the text is inserted the phone switches back to the previous keyboard by itself.

## Troubleshooting

| Message on the keyboard | What to do |
|---|---|
| Mac unreachable | Wake the Mac, check that *Allow Phone Dictation* is on and that the phone is on the same Wi-Fi or Tailscale, then tap **Retry**. |
| Token rejected | The token was regenerated on the Mac. Tap **Pair again**, scan the new code, then **Retry**. |
| No model selected on the Mac | Choose a transcription model in VoiceInk, then **Retry**. |
| Transcription failed | The Mac could not decode or transcribe the recording. **Retry**, or **Discard** and record again. |

## Code layout

| Path | Role |
|---|---|
| `api/VoiceInkClient.kt` | HTTP client and error mapping for the phone dictation API. Tries the Mac's hosts in order, but never re-sends a recording once a host accepted the connection. |
| `api/Pairing.kt` | Pairing model and QR / manual-entry parsing. |
| `store/` | Encrypted pairing storage and the kept recording. |
| `ime/VoiceKeyboardService.kt` | The keyboard (input method service). |
| `setup/MainActivity.kt` | Pairing and keyboard setup screen. |
