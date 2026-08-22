# Building VoiceInk

## Requirements

- macOS 14.4 or later
- Xcode with Command Line Tools
- Git

## Local Build

```bash
git clone git@github.com:dguay/VoiceInk.git
cd VoiceInk
make bootstrap
open ~/Downloads/VoiceInk.app
```

`make bootstrap` discovers the clone from its own location, validates `dguay/VoiceInk` as `origin`, adds or validates `Beingpax/VoiceInk` as `upstream`, and records the clone path in global Git configuration as `voiceink.repositoryPath`. It also checks GitHub push access, Xcode and Command Line Tools, 15 GiB of free disk space, and permission to replace `/Applications/VoiceInk.app`. Override the last two checks with `VOICEINK_MIN_FREE_GIB` and `VOICEINK_INSTALLED_APP_PATH` when needed.

A missing or unauthenticated Codex CLI produces a warning but does not stop bootstrap. After preflight checks, bootstrap prepares `whisper.xcframework` in `~/VoiceInk-Dependencies`, builds in `.local-build`, and copies `VoiceInk.app` to `~/Downloads`.

It uses `LocalBuild.xcconfig`, `VoiceInk.local.entitlements`, and the `LOCAL_BUILD` Swift flag. Without an override, it uses the only available Apple Development identity or falls back to ad-hoc signing when none or multiple are found.

After bootstrap, a local build's update controls prepare `origin/main` in a temporary worktree. VoiceInk runs the updater tests and non-UI unit tests, builds the candidate, validates its signature and source metadata, and stages it under Application Support. The registered clone must be clean. Preparation never resets or cleans it, and VoiceInk keeps running while the update waits for an explicit restart.

Choose an identity explicitly:

```bash
make local LOCAL_CODESIGN_IDENTITY="<SHA or name>"
```

Force ad-hoc signing:

```bash
make local LOCAL_CODESIGN_IDENTITY=-
```

Local builds do not include iCloud dictionary sync or automatic updates. They embed the exact fork commit and newest contained `upstream/main` commit, which appear in Settings under General. Ad-hoc builds may require macOS permissions again after rebuilding. Normal project Debug and Release settings are unchanged.

## Other Commands

- `make check` — verify required tools
- `make bootstrap` — register the clone, run local-update preflights, and build with source provenance
- `make whisper` — prepare `whisper.xcframework`
- `make build` — build the standard Debug configuration
- `make dev` — build and launch the app
- `make run` — launch `~/Downloads/VoiceInk.app`, or the first app found in DerivedData
- `make release` — create the signed release package
- `make release-setup` — configure release notarization credentials
- `make clean` — remove `~/VoiceInk-Dependencies`
- `make help` — list all commands

## Build with Xcode

```bash
make setup
open VoiceInk.xcodeproj
```

Select the `VoiceInk` scheme and use the Debug configuration. Xcode uses the project’s normal signing settings; `LOCAL_BUILD` applies only through `make local`.

## Troubleshooting

- Run `make check` to verify the required tools.
- Run `make whisper` if the framework is missing.
- If several Apple Development identities exist, set `LOCAL_CODESIGN_IDENTITY` explicitly.
- For additional help, open a [GitHub issue](https://github.com/Beingpax/VoiceInk/issues).
