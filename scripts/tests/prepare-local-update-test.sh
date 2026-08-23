#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/voiceink-prepare-update-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

fork_bare="$fixture_root/fork.git"
upstream_bare="$fixture_root/upstream.git"
seed_clone="$fixture_root/seed"
canonical_clone="$fixture_root/canonical"
manifest_path="$fixture_root/staging/staged-candidate.plist"
recovery_state="$fixture_root/recovery/recovery.plist"

git init --bare --initial-branch=main "$fork_bare" >/dev/null
git init --bare --initial-branch=main "$upstream_bare" >/dev/null
git init --initial-branch=main "$seed_clone" >/dev/null
git -C "$seed_clone" config user.name "VoiceInk Updater Test"
git -C "$seed_clone" config user.email "updater-test@example.com"
printf 'fixture\n' > "$seed_clone/README.md"
git -C "$seed_clone" add README.md
git -C "$seed_clone" commit -m "test: seed updater fixture" >/dev/null
git -C "$seed_clone" remote add origin "$fork_bare"
git -C "$seed_clone" remote add upstream "$upstream_bare"
git -C "$seed_clone" push -u origin main >/dev/null
git -C "$seed_clone" push upstream main >/dev/null
git clone "$fork_bare" "$canonical_clone" >/dev/null
git -C "$canonical_clone" remote add upstream "$upstream_bare"

printf 'keep this work\n' > "$canonical_clone/uncommitted.txt"
before_status="$(git -C "$canonical_clone" status --porcelain)"
before_head="$(git -C "$canonical_clone" rev-parse HEAD)"

if VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$manifest_path" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
    > "$fixture_root/dirty-output.log" 2>&1
then
    printf 'prepare-local-update-test: dirty checkout was accepted\n' >&2
    exit 1
fi

after_status="$(git -C "$canonical_clone" status --porcelain)"
after_head="$(git -C "$canonical_clone" rev-parse HEAD)"

[[ "$after_status" == "$before_status" ]]
[[ "$after_head" == "$before_head" ]]
[[ -f "$canonical_clone/uncommitted.txt" ]]
[[ ! -e "$manifest_path" ]]
grep -Fq "uncommitted changes" "$fixture_root/dirty-output.log"

rm "$canonical_clone/uncommitted.txt"
printf 'candidate\n' > "$seed_clone/candidate-marker"
git -C "$seed_clone" add candidate-marker
git -C "$seed_clone" commit -m "feat: publish candidate" >/dev/null
git -C "$seed_clone" push origin main >/dev/null
candidate_sha="$(git -C "$seed_clone" rev-parse HEAD)"
upstream_sha="$(git -C "$seed_clone" rev-parse HEAD^)"

fake_bin="$fixture_root/bin"
xcode_log="$fixture_root/xcodebuild.log"
mkdir -p "$fake_bin"

cat > "$fake_bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ "$PWD" != "$CANONICAL_PATH" ]]
[[ -f "$PWD/candidate-marker" ]]
printf '%s|%s\n' "$PWD" "$*" >> "$XCODE_LOG"

derived_data=""
fork_commit=""
upstream_commit=""
arguments=("$@")
for ((index = 0; index < ${#arguments[@]}; index++)); do
    case "${arguments[$index]}" in
        -derivedDataPath) derived_data="${arguments[$((index + 1))]}" ;;
        VOICEINK_FORK_COMMIT=*) fork_commit="${arguments[$index]#VOICEINK_FORK_COMMIT=}" ;;
        VOICEINK_UPSTREAM_COMMIT=*) upstream_commit="${arguments[$index]#VOICEINK_UPSTREAM_COMMIT=}" ;;
    esac
done

if [[ " ${arguments[*]} " == *" build "* ]]; then
    app_path="$derived_data/Build/Products/Debug/VoiceInk.app"
    mkdir -p "$app_path/Contents/MacOS"
    printf 'fixture executable\n' > "$app_path/Contents/MacOS/VoiceInk"
    /usr/bin/plutil -create xml1 "$app_path/Contents/Info.plist"
    /usr/bin/plutil -insert VoiceInkForkCommit -string "${FORK_COMMIT_OVERRIDE:-$fork_commit}" "$app_path/Contents/Info.plist"
    /usr/bin/plutil -insert VoiceInkUpstreamCommit -string "$upstream_commit" "$app_path/Contents/Info.plist"
    /usr/bin/plutil -insert VoiceInkUpdaterKind -string "${UPDATER_KIND_OVERRIDE:-fork}" "$app_path/Contents/Info.plist"
fi
EOF

cat > "$fake_bin/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -d "${@: -1}" ]]
[[ "${CODESIGN_SHOULD_FAIL:-0}" != 1 ]]
EOF

chmod +x "$fake_bin/xcodebuild" "$fake_bin/codesign"

mkdir -p "$(dirname "$recovery_state")"
/usr/bin/plutil -create xml1 "$recovery_state"
/usr/bin/plutil -insert previousForkCommit -string "$upstream_sha" "$recovery_state"
/usr/bin/plutil -insert candidateForkCommit -string "$candidate_sha" "$recovery_state"
/usr/bin/plutil -insert suppressedForkCommit -string "$candidate_sha" "$recovery_state"

if PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$manifest_path" \
    VOICEINK_UPDATE_RECOVERY_STATE_PATH="$recovery_state" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
    > "$fixture_root/suppressed-output.log" 2>&1
then
    printf 'prepare-local-update-test: rolled-back candidate was prepared again\n' >&2
    exit 1
fi
[[ ! -e "$manifest_path" ]]
grep -Fq "suppressed" "$fixture_root/suppressed-output.log"

PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$manifest_path" \
    VOICEINK_UPDATE_RECOVERY_STATE_PATH="$recovery_state" \
    VOICEINK_UPDATE_RETRY_SUPPRESSED_CANDIDATE=1 \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"

[[ "$(git -C "$canonical_clone" rev-parse HEAD)" == "$before_head" ]]
[[ "$(git -C "$canonical_clone" status --porcelain)" == "" ]]
[[ "$(git -C "$canonical_clone" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]
[[ "$(/usr/bin/plutil -extract forkCommit raw "$manifest_path")" == "$candidate_sha" ]]
[[ "$(/usr/bin/plutil -extract upstreamCommit raw "$manifest_path")" == "$upstream_sha" ]]
if /usr/bin/plutil -extract suppressedForkCommit raw "$recovery_state" >/dev/null 2>&1; then
    printf 'prepare-local-update-test: explicit retry did not clear candidate suppression\n' >&2
    exit 1
fi
staged_bundle="$(/usr/bin/plutil -extract bundlePath raw "$manifest_path")"
[[ -d "$staged_bundle" ]]
grep -Fq -- '-only-testing:VoiceInkTests/UpdaterViewModelTests' "$xcode_log"
grep -Fq -- '-only-testing:VoiceInkTests test' "$xcode_log"
grep -Fq -- ' build' "$xcode_log"

signature_manifest="$fixture_root/rejected-signature/staged-candidate.plist"
if PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    CODESIGN_SHOULD_FAIL=1 \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$signature_manifest" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
    > "$fixture_root/signature-output.log" 2>&1
then
    printf 'prepare-local-update-test: invalid signature was accepted\n' >&2
    exit 1
fi
[[ ! -e "$signature_manifest" ]]
grep -Fq "failed signature validation" "$fixture_root/signature-output.log"

provenance_manifest="$fixture_root/rejected-provenance/staged-candidate.plist"
if PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    FORK_COMMIT_OVERRIDE=0000000000000000000000000000000000000000 \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$provenance_manifest" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
    > "$fixture_root/provenance-output.log" 2>&1
then
    printf 'prepare-local-update-test: invalid provenance was accepted\n' >&2
    exit 1
fi
[[ ! -e "$provenance_manifest" ]]
grep -Fq "wrong fork provenance" "$fixture_root/provenance-output.log"

updater_manifest="$fixture_root/rejected-updater/staged-candidate.plist"
if PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    UPDATER_KIND_OVERRIDE=official \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$updater_manifest" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
    > "$fixture_root/updater-output.log" 2>&1
then
    printf 'prepare-local-update-test: official updater candidate was accepted\n' >&2
    exit 1
fi
[[ ! -e "$updater_manifest" ]]
grep -Fq "does not contain the local fork updater" "$fixture_root/updater-output.log"
[[ "$(git -C "$canonical_clone" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]

printf 'prepare-local-update-test: PASS\n'
