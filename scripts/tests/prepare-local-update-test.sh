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
result_path="$fixture_root/staging/preparation-result.plist"
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

deferred_manifest="$fixture_root/deferred/staged-candidate.plist"
deferred_result="$fixture_root/deferred/preparation-result.plist"
PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$deferred_manifest" \
    VOICEINK_UPDATE_RESULT_PATH="$deferred_result" \
    VOICEINK_INSTALLED_FORK_COMMIT="$upstream_sha" \
    VOICEINK_UPDATE_DEFER_BUILD=1 \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"

if [[ -e "$deferred_manifest" || -e "$xcode_log" || ! -f "$deferred_result" ]]; then
    printf 'prepare-local-update-test: deferred automatic check built or staged a candidate\n' >&2
    exit 1
fi
if [[ "$(/usr/bin/plutil -extract outcome raw "$deferred_result")" != "buildDeferred" \
    || "$(/usr/bin/plutil -extract forkCommit raw "$deferred_result")" != "$candidate_sha" \
    || "$(/usr/bin/plutil -extract upstreamCommit raw "$deferred_result")" != "$upstream_sha" ]]
then
    printf 'prepare-local-update-test: deferred automatic check reported the wrong candidate\n' >&2
    exit 1
fi

up_to_date_manifest="$fixture_root/up-to-date/staged-candidate.plist"
up_to_date_result="$fixture_root/up-to-date/preparation-result.plist"
PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$up_to_date_manifest" \
    VOICEINK_UPDATE_RESULT_PATH="$up_to_date_result" \
    VOICEINK_INSTALLED_FORK_COMMIT="$candidate_sha" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"

if [[ -e "$up_to_date_manifest" || -e "$xcode_log" || ! -f "$up_to_date_result" ]]; then
    printf 'prepare-local-update-test: exact installed fork did not stop before build and staging\n' >&2
    exit 1
fi
if [[ "$(/usr/bin/plutil -extract outcome raw "$up_to_date_result")" != "upToDate" \
    || "$(/usr/bin/plutil -extract forkCommit raw "$up_to_date_result")" != "$candidate_sha" \
    || "$(/usr/bin/plutil -extract upstreamCommit raw "$up_to_date_result")" != "$upstream_sha" ]]
then
    printf 'prepare-local-update-test: exact installed fork reported the wrong provenance\n' >&2
    exit 1
fi

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
    VOICEINK_UPDATE_RESULT_PATH="$result_path" \
    VOICEINK_UPDATE_RECOVERY_STATE_PATH="$recovery_state" \
    VOICEINK_UPDATE_RETRY_SUPPRESSED_CANDIDATE=1 \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"

[[ "$(git -C "$canonical_clone" rev-parse HEAD)" == "$before_head" ]]
[[ "$(git -C "$canonical_clone" status --porcelain)" == "" ]]
[[ "$(git -C "$canonical_clone" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]
[[ "$(/usr/bin/plutil -extract forkCommit raw "$manifest_path")" == "$candidate_sha" ]]
[[ "$(/usr/bin/plutil -extract upstreamCommit raw "$manifest_path")" == "$upstream_sha" ]]
if [[ "$(/usr/bin/plutil -extract outcome raw "$result_path")" != "candidatePrepared" ]]; then
    printf 'prepare-local-update-test: staged candidate did not report preparation success\n' >&2
    exit 1
fi
if /usr/bin/plutil -extract suppressedForkCommit raw "$recovery_state" >/dev/null 2>&1; then
    printf 'prepare-local-update-test: explicit retry did not clear candidate suppression\n' >&2
    exit 1
fi
staged_bundle="$(/usr/bin/plutil -extract bundlePath raw "$manifest_path")"
[[ -d "$staged_bundle" ]]
grep -Fq -- '-only-testing:VoiceInkTests/UpdaterViewModelTests' "$xcode_log"
grep -Fq -- '-only-testing:VoiceInkTests test' "$xcode_log"
grep -Fq -- ' build' "$xcode_log"

stable_signing_config="$fixture_root/stable-signing.gitconfig"
stable_signing_manifest="$fixture_root/stable-signing/staged-candidate.plist"
stable_signing_xcode_log="$fixture_root/stable-signing-xcodebuild.log"
git config --file "$stable_signing_config" voiceink.localCodesignIdentity "VoiceInk Local Development"

PATH="$fake_bin:$PATH" \
    GIT_CONFIG_GLOBAL="$stable_signing_config" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$stable_signing_xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$stable_signing_manifest" \
    VOICEINK_UPDATE_RECOVERY_STATE_PATH="$recovery_state" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"

grep -Fq -- 'VOICEINK_LOCAL_CODESIGN_IDENTITY=VoiceInk Local Development' "$stable_signing_xcode_log"
grep -Fq -- 'CODE_SIGNING_REQUIRED=YES' "$stable_signing_xcode_log"

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

printf 'upstream-only\n' > "$seed_clone/upstream-marker"
git -C "$seed_clone" add upstream-marker
git -C "$seed_clone" commit -m "feat: advance upstream" >/dev/null
git -C "$seed_clone" push upstream main >/dev/null
upstream_fast_forward_sha="$(git -C "$seed_clone" rev-parse HEAD)"
fast_forward_manifest="$fixture_root/fast-forward/staged-candidate.plist"

PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$fast_forward_manifest" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"

[[ "$(/usr/bin/plutil -extract forkCommit raw "$fast_forward_manifest")" == "$upstream_fast_forward_sha" ]]
[[ "$(/usr/bin/plutil -extract forkBaseCommit raw "$fast_forward_manifest")" == "$candidate_sha" ]]
[[ "$(/usr/bin/plutil -extract upstreamCommit raw "$fast_forward_manifest")" == "$upstream_fast_forward_sha" ]]
fast_forward_candidate_ref="$(/usr/bin/plutil -extract candidateRef raw "$fast_forward_manifest")"
fast_forward_staged_bundle="$(/usr/bin/plutil -extract bundlePath raw "$fast_forward_manifest")"
fast_forward_candidate_stage="$(dirname "$fast_forward_staged_bundle")"
[[ "$(git -C "$canonical_clone" rev-parse "$fast_forward_candidate_ref")" == "$upstream_fast_forward_sha" ]]
[[ "$(git -C "$canonical_clone" rev-parse HEAD)" == "$before_head" ]]
[[ "$(git -C "$canonical_clone" status --porcelain)" == "" ]]
[[ "$(git -C "$canonical_clone" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]

publication_retry_result="$fixture_root/fast-forward/preparation-result.plist"
xcode_lines_before_retry="$(wc -l < "$xcode_log")"
PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$fast_forward_manifest" \
    VOICEINK_UPDATE_RESULT_PATH="$publication_retry_result" \
    VOICEINK_INSTALLED_FORK_COMMIT="$upstream_fast_forward_sha" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"
[[ "$(/usr/bin/plutil -extract outcome raw "$publication_retry_result")" == "candidatePrepared" ]]
[[ "$(/usr/bin/plutil -extract candidateRef raw "$fast_forward_manifest")" == "$fast_forward_candidate_ref" ]]
[[ -d "$fast_forward_staged_bundle" ]]
[[ "$(git -C "$canonical_clone" rev-parse "$fast_forward_candidate_ref")" == "$upstream_fast_forward_sha" ]]
[[ "$(wc -l < "$xcode_log")" -eq "$xcode_lines_before_retry" ]]

second_fast_forward_manifest="$fixture_root/fast-forward-second/staged-candidate.plist"
PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$second_fast_forward_manifest" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"
second_fast_forward_candidate_ref="$(/usr/bin/plutil -extract candidateRef raw "$second_fast_forward_manifest")"
[[ "$second_fast_forward_candidate_ref" != "$fast_forward_candidate_ref" ]]
[[ "$(git -C "$canonical_clone" rev-parse "$fast_forward_candidate_ref")" == "$upstream_fast_forward_sha" ]]
[[ "$(git -C "$canonical_clone" rev-parse "$second_fast_forward_candidate_ref")" == "$upstream_fast_forward_sha" ]]

PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$fast_forward_manifest" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"
replacement_candidate_ref="$(/usr/bin/plutil -extract candidateRef raw "$fast_forward_manifest")"
[[ "$replacement_candidate_ref" != "$fast_forward_candidate_ref" ]]
[[ ! -e "$fast_forward_candidate_stage" ]]
if git -C "$canonical_clone" rev-parse "$fast_forward_candidate_ref" >/dev/null 2>&1; then
    printf 'prepare-local-update-test: superseded candidate reference was not cleaned up\n' >&2
    exit 1
fi
[[ "$(git -C "$canonical_clone" rev-parse "$replacement_candidate_ref")" == "$upstream_fast_forward_sha" ]]
[[ "$(git -C "$canonical_clone" rev-parse "$second_fast_forward_candidate_ref")" == "$upstream_fast_forward_sha" ]]

fork_writer="$fixture_root/fork-writer"
git clone "$fork_bare" "$fork_writer" >/dev/null
git -C "$fork_writer" config user.name "VoiceInk Fork Writer"
git -C "$fork_writer" config user.email "fork-writer@example.com"
printf 'fork-only\n' > "$fork_writer/fork-marker"
git -C "$fork_writer" add fork-marker
git -C "$fork_writer" commit -m "feat: advance fork" >/dev/null
git -C "$fork_writer" push origin main >/dev/null
diverged_fork_sha="$(git -C "$fork_writer" rev-parse HEAD)"
merge_manifest="$fixture_root/merge/staged-candidate.plist"
git -C "$canonical_clone" config user.useConfigOnly true
git -C "$canonical_clone" config --unset-all user.name >/dev/null 2>&1 || true
git -C "$canonical_clone" config --unset-all user.email >/dev/null 2>&1 || true

GIT_CONFIG_GLOBAL=/dev/null \
    PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$merge_manifest" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"

merge_candidate_sha="$(/usr/bin/plutil -extract forkCommit raw "$merge_manifest")"
[[ "$(/usr/bin/plutil -extract forkBaseCommit raw "$merge_manifest")" == "$diverged_fork_sha" ]]
[[ "$(/usr/bin/plutil -extract upstreamCommit raw "$merge_manifest")" == "$upstream_fast_forward_sha" ]]
merge_subject="$(git -C "$canonical_clone" show -s --format=%s "$merge_candidate_sha")"
printf '%s\n' "$merge_subject" | grep -Eq '^[a-z]+(\([a-z0-9-]+\))?!?: .+'
[[ "$(git -C "$canonical_clone" show -s --format='%P' "$merge_candidate_sha")" == "$diverged_fork_sha $upstream_fast_forward_sha" ]]
[[ "$(git -C "$canonical_clone" rev-parse refs/remotes/origin/main)" == "$diverged_fork_sha" ]]
merge_candidate_ref="$(/usr/bin/plutil -extract candidateRef raw "$merge_manifest")"
[[ "$(git -C "$canonical_clone" rev-parse "$merge_candidate_ref")" == "$merge_candidate_sha" ]]
[[ "$(git -C "$canonical_clone" rev-parse HEAD)" == "$before_head" ]]
[[ "$(git -C "$canonical_clone" status --porcelain)" == "" ]]
[[ "$(git -C "$canonical_clone" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]

printf 'fork-conflict\n' > "$fork_writer/README.md"
git -C "$fork_writer" add README.md
git -C "$fork_writer" commit -m "feat: change fork readme" >/dev/null
git -C "$fork_writer" push origin main >/dev/null
printf 'upstream-conflict\n' > "$seed_clone/README.md"
git -C "$seed_clone" add README.md
git -C "$seed_clone" commit -m "feat: change upstream readme" >/dev/null
git -C "$seed_clone" push upstream main >/dev/null
conflict_manifest="$fixture_root/conflict/staged-candidate.plist"

if PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$conflict_manifest" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
    > "$fixture_root/conflict-output.log" 2>&1
then
    printf 'prepare-local-update-test: conflicting histories produced a candidate\n' >&2
    exit 1
fi
[[ ! -e "$conflict_manifest" ]]
[[ "$(git -C "$canonical_clone" rev-parse HEAD)" == "$before_head" ]]
[[ "$(git -C "$canonical_clone" status --porcelain)" == "" ]]
[[ "$(git -C "$canonical_clone" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]
if [[ "$(grep -Fc 'The fetched fork conflicts with upstream/main. Resolve the shared fork before retrying.' "$fixture_root/conflict-output.log")" -ne 1 ]]; then
    printf 'prepare-local-update-test: first Mac did not receive one actionable conflict\n' >&2
    exit 1
fi

second_canonical_clone="$fixture_root/canonical-second-mac"
second_conflict_manifest="$fixture_root/conflict-second-mac/staged-candidate.plist"
git clone "$fork_bare" "$second_canonical_clone" >/dev/null
git -C "$second_canonical_clone" remote add upstream "$upstream_bare"
second_before_head="$(git -C "$second_canonical_clone" rev-parse HEAD)"

if PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$second_canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$second_canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$second_conflict_manifest" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
    > "$fixture_root/conflict-second-mac-output.log" 2>&1
then
    printf 'prepare-local-update-test: second Mac produced a conflicting candidate\n' >&2
    exit 1
fi
[[ ! -e "$second_conflict_manifest" ]]
[[ "$(git -C "$second_canonical_clone" rev-parse HEAD)" == "$second_before_head" ]]
[[ "$(git -C "$second_canonical_clone" status --porcelain)" == "" ]]
[[ "$(git -C "$second_canonical_clone" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]
if [[ "$(grep -Fc 'The fetched fork conflicts with upstream/main. Resolve the shared fork before retrying.' "$fixture_root/conflict-second-mac-output.log")" -ne 1 ]]; then
    printf 'prepare-local-update-test: second Mac did not receive one actionable conflict\n' >&2
    exit 1
fi

history_fork_bare="$fixture_root/history-fork.git"
history_seed="$fixture_root/history-seed"
history_clone="$fixture_root/history-clone"
history_manifest="$fixture_root/history/staged-candidate.plist"
git init --bare --initial-branch=main "$history_fork_bare" >/dev/null
git init --initial-branch=main "$history_seed" >/dev/null
git -C "$history_seed" config user.name "VoiceInk Updater Test"
git -C "$history_seed" config user.email "updater-test@example.com"
printf 'published\n' > "$history_seed/version"
git -C "$history_seed" add version
git -C "$history_seed" commit -m "test: seed published history" >/dev/null
git -C "$history_seed" remote add origin "$history_fork_bare"
git -C "$history_seed" push -u origin main >/dev/null
git clone "$history_fork_bare" "$history_clone" >/dev/null
git -C "$history_clone" remote add upstream "$history_fork_bare"
printf 'installed-only\n' > "$history_seed/version"
git -C "$history_seed" add version
git -C "$history_seed" commit -m "test: record installed-only history" >/dev/null
installed_only_sha="$(git -C "$history_seed" rev-parse HEAD)"

if PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$history_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$history_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$history_manifest" \
    VOICEINK_INSTALLED_FORK_COMMIT="$installed_only_sha" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
    > "$fixture_root/history-output.log" 2>&1
then
    printf 'prepare-local-update-test: older fork history was accepted\n' >&2
    exit 1
fi
[[ ! -e "$history_manifest" ]]
grep -Fq "does not descend from the installed VoiceInk revision" "$fixture_root/history-output.log"

printf 'prepare-local-update-test: PASS\n'
