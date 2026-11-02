# Building VoiceInk

## Requirements

- macOS 15.0 or later
- Xcode with Command Line Tools
- Git

## Local Build

```bash
git clone git@github.com:dguay/VoiceInk.git
cd VoiceInk
make bootstrap
open ~/Downloads/VoiceInk.app
```

`make bootstrap` discovers the clone from its own location, validates `dguay/VoiceInk` as `origin`, adds or validates `Beingpax/VoiceInk` as `upstream`, makes `origin` the GitHub CLI's default repository (as `gh repo set-default` does), and records the clone path in global Git configuration as `voiceink.repositoryPath`. It also checks GitHub push access, Xcode and Command Line Tools, 15 GiB of free disk space, and permission to replace `/Applications/VoiceInk.app`. Override the last two checks with `VOICEINK_MIN_FREE_GIB` and `VOICEINK_INSTALLED_APP_PATH` when needed.

A missing or unauthenticated Codex CLI produces a warning but does not stop bootstrap. After preflight checks, bootstrap runs `make test-updater`; a failing suite stops bootstrap before it registers the clone or builds. It then prepares `whisper.xcframework` in `~/VoiceInk-Dependencies`, builds Release in `.local-build`, and copies `VoiceInk.app` to `~/Downloads`.

It uses `LocalBuild.xcconfig`, `VoiceInk.local.entitlements`, and the `LOCAL_BUILD` Swift flag. Without an override, it uses the only available Apple Development identity or falls back to ad-hoc signing when none or multiple are found.

After bootstrap, a local build's update controls prepare `origin/main` in a temporary worktree. VoiceInk runs the non-UI unit tests (which include the updater tests) once, builds the candidate, validates its signature and source metadata, and stages it under Application Support. The registered clone must be clean. Preparation never resets or cleans it, and VoiceInk keeps running while the update waits for an explicit restart.

Preparation is bounded and unattended. Git never prompts for credentials or SSH passphrases, the Mac does not idle-sleep during a run, and a run that exceeds 45 minutes is stopped and reported as a temporary failure. Settings shows the current stage and elapsed time, and Settings or the menu bar can cancel a run. Derived data and Swift packages persist in `~/Library/Application Support/com.prakashjoshipax.VoiceInk/Updater/BuildCache`, so later preparations are incremental; delete that folder to force a clean build. Automatic checks fetch but skip the build in Low Power Mode, on battery power, or under serious thermal pressure; manual checks always build. Before building, preparation stops if the candidate would be signed with a different identity than the installed app, and names both identities. Candidate references and staged bundles that nothing uses, that are older than 14 days, and that the fork's `main` does not contain are pruned.

`Restart and Update` approves only the staged candidate SHA. The on-demand installer fetches `origin/main` again before quitting VoiceInk, preserves the current app, replaces it from a same-volume copy, and waits for the new app's provenance handshake and stability window. A stale candidate returns to preparation without quitting VoiceInk. A launch or health failure restores and relaunches the preserved app.

Choose an identity explicitly:

```bash
make local LOCAL_CODESIGN_IDENTITY="<SHA or name>"
```

Persist an identity for both manual builds and in-app updates:

```bash
git config --global voiceink.localCodesignIdentity "<SHA or name>"
```

`LOCAL_CODESIGN_IDENTITY` takes precedence over the persisted setting.

Force ad-hoc signing:

```bash
make local LOCAL_CODESIGN_IDENTITY=-
```

Local builds do not include iCloud dictionary sync or automatic updates. They embed the exact fork commit and newest contained `upstream/main` commit, which appear in Settings under General. Ad-hoc builds may require macOS permissions again after rebuilding. Normal project Debug and Release settings are unchanged.

## Updater Tests

```bash
make test-updater
```

`make test-updater` runs the updater shell test suites in `scripts/tests` and prints `PASS` or `FAIL` for each, followed by a summary. It runs every suite even after a failure and exits non-zero if any suite fails or is missing. The suites run against temporary fixtures with stubbed tools, so they need no network, signing identity, or Xcode build, and take under a minute.

| Suite | Covers |
|---|---|
| `bootstrap-local-test.sh` | `scripts/bootstrap-local.sh` remote, push-access, install-path and disk checks, clone registration, and the build hand-off |
| `prepare-local-update-test.sh` | `prepare-local-update.sh` candidate preparation, build caches, signing-identity preflight, pruning, cleanup after termination, staging, and publication of a retained installed candidate |
| `install-local-update-test.sh` | `install-local-update.sh` approval, app replacement, relaunch, rollback, and post-health publication failures |
| `restore-local-update-test.sh` | `restore-local-update.sh` recovery of the preserved app and its state |
| `test-updater-test.sh` | The runner's own pass, fail and missing-suite reporting |

Run a single suite directly by path, for example `bash scripts/tests/install-local-update-test.sh`.

## Other Commands

- `make check` — verify required tools
- `make bootstrap` — register the clone, run local-update preflights, and build with source provenance
- `make test-updater` — run the updater shell test suites
- `make whisper` — prepare `whisper.xcframework`
- `make build` — build the standard Debug configuration
- `make dev` — build and launch `VoiceInk Dev.app`
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

Select the `VoiceInk` scheme. Run builds `VoiceInk Dev.app`; Archive uses Release. `LOCAL_BUILD` applies only through `make local`.

## Troubleshooting

- Run `make check` to verify the required tools.
- Run `make whisper` if the framework is missing.
- If several Apple Development identities exist, set `LOCAL_CODESIGN_IDENTITY` explicitly.
- For additional help, open a [GitHub issue](https://github.com/Beingpax/VoiceInk/issues).
