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
- **Mic bubble** (optional): keep your usual keyboard (SwiftKey, Gboard…) and dictate from a
  floating mic docked just above it. See [Mic bubble](#mic-bubble).
- **Failures**: "Mac unreachable", "Token rejected", "No model selected on the Mac" and
  "Transcription failed" are shown on the keyboard and on the bubble. The recording is kept until
  its text is inserted, so **Retry** sends it again once the Mac is back; **Discard** drops it.

The API is described in [`docs/phone-dictation-api.md`](../docs/phone-dictation-api.md).
Requires Android 10 (API 29) or later.

## Build

Requirements: JDK 17+ and the Android SDK (platform 36). Point Gradle at the SDK with
`ANDROID_HOME` or a `local.properties` file containing `sdk.dir=/path/to/Android/sdk`.

```sh
cd android
./gradlew assembleDebug          # app/build/outputs/apk/debug/app-debug.apk
./gradlew testDebugUnitTest      # unit tests
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
4. **Open VoiceInk Keyboard** on the phone and follow the steps:
   1. *Pair*: tap **Scan QR code** and scan the code on the Mac, or type the address shown under
      the code (LAN address, or the `100.x.y.z` Tailscale address when away from home), the port
      and the token (**Copy** on the Mac). The phone must be on the same network as the Mac or on
      the same Tailscale tailnet.
   2. *Allow the microphone*.
   3. *Turn on the keyboard*: **Open keyboard settings**, turn on **VoiceInk voice** and accept the
      system warning. Keep SwiftKey as the default keyboard.
   4. *Switch to it while typing* (below).
   5. *Enable the mic bubble* (optional, below).

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

## Mic bubble

For keyboards with their own dictation that cannot hand off to another keyboard (SwiftKey), the
app also offers a floating mic bubble:

- **Turn it on**: setup step 5, **Open accessibility settings** → *VoiceInk mic bubble* (under
  *Downloaded apps* or *Installed apps*) → turn it on and accept the warning. Android lists the
  bubble as an accessibility service because it has to see when a keyboard opens and which field
  has focus; it reads nothing else, and only the recording goes to your paired Mac. If the switch is
  greyed out on a sideloaded APK (Android 13+), open *App info* → ⋮ → *Allow restricted settings*
  first.
- **When it shows**: only while a keyboard is open over a text field, in any app. It hides in
  password fields, when the keyboard closes, and while the VoiceInk voice keyboard itself is open.
  It docks just above the keyboard on the right, and moves to the left or above the field rather
  than cover the field you are typing in.
- **Dictating**: tap the bubble to record, tap again to send. The text goes through the same Mac
  pipeline as the keyboard and is inserted at the cursor of the field the bubble was showing for.
  If you move to another field or close the keyboard first, the text is not typed anywhere; the
  recording is kept and **Retry** inserts it into the field open at that time.
- **Limitation**: the bubble inserts text with the accessibility "set text" action, which works in
  standard Android text fields and most apps; a few custom editors (some web pages and games)
  ignore it, and the bubble then shows "This field didn't accept the text" with the recording kept.
- Force-stopping the app (or reinstalling it with some tools) turns the service off; turn it on
  again in step 5.

## Troubleshooting

| Message on the keyboard or bubble | What to do |
|---|---|
| Mac unreachable | Wake the Mac, check that *Allow Phone Dictation* is on and that the phone is on the same Wi-Fi or Tailscale, then tap **Retry**. |
| Token rejected | The token was regenerated on the Mac. Tap **Pair again**, scan the new code, then **Retry**. |
| No model selected on the Mac | Choose a transcription model in VoiceInk, then **Retry**. |
| Transcription failed | The Mac could not decode or transcribe the recording. **Retry**, or **Discard** and record again. |

## Code layout

| Path | Role |
|---|---|
| `dictation/` | Record → send → type-into-the-recorded-field flow, its states and messages, shared by the keyboard and the bubble. |
| `api/VoiceInkClient.kt` | HTTP client and error mapping for the phone dictation API. Tries the Mac's hosts in order, but never re-sends a recording once a host accepted the connection. |
| `api/Pairing.kt` | Pairing model and QR / manual-entry parsing. |
| `store/` | Encrypted pairing storage and the kept recording. |
| `ime/VoiceKeyboardService.kt` | The keyboard (input method service). |
| `bubble/` | The mic bubble: accessibility service, overlay window, and its visibility, field and placement rules. |
| `setup/MainActivity.kt` | Pairing and keyboard setup screen. |
