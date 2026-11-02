#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/voiceink-prepare-update-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
# Keep the suite independent of the developer's global Git settings, such as a
# persisted signing identity. Scenarios that need one pass their own file.
export GIT_CONFIG_GLOBAL="$fixture_root/empty-global.gitconfig"
: > "$GIT_CONFIG_GLOBAL"

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
canonical_repository_path="$(cd "$canonical_clone" && pwd -P)"

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

if [[ -n "${XCODE_HANG_MARKER:-}" ]]; then
    : > "$XCODE_HANG_MARKER"
    sleep 600
fi

if [[ "${XCODE_SHOULD_FAIL:-0}" == 1 ]]; then
    printf 'error: deterministic updater test failure\n' >&2
    exit 1
fi

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
    app_path="$derived_data/Build/Products/Release/VoiceInk.app"
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
for argument in "$@"; do
    case "$argument" in
        --extract-certificates=*)
            [[ -n "${INSTALLED_LEAF_CERTIFICATE:-}" ]] || exit 1
            printf '%s' "$INSTALLED_LEAF_CERTIFICATE" > "${argument#--extract-certificates=}0"
            exit 0
            ;;
    esac
done
for argument in "$@"; do
    case "$argument" in
        -d | --display)
            printf '%b\n' "${INSTALLED_SIGNATURE_DETAILS:-Signature=adhoc}" >&2
            exit 0
            ;;
    esac
done
[[ -d "${@: -1}" ]]
[[ "${CODESIGN_SHOULD_FAIL:-0}" != 1 ]]
EOF

cat > "$fake_bin/caffeinate" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${CAFFEINATE_LOG:-}" ]]; then
    printf '%s\n' "$*" >> "$CAFFEINATE_LOG"
fi
EOF

# Lists the valid signing identities given as "SHA-1|name" lines, the way
# `security find-identity -v -p codesigning` prints them.
cat > "$fake_bin/security" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "find-identity -v -p codesigning" ]] || exit 1
count=0
while IFS='|' read -r hash name; do
    [[ -n "$hash" ]] || continue
    count=$((count + 1))
    printf '  %d) %s "%s"\n' "$count" "$hash" "$name"
done < <(printf '%b\n' "${CODESIGNING_IDENTITIES:-}")
printf '     %d valid identities found\n' "$count"
EOF

chmod +x "$fake_bin/xcodebuild" "$fake_bin/codesign" "$fake_bin/caffeinate" "$fake_bin/security"

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

fetch_failure_manifest="$fixture_root/fetch-failure/staged-candidate.plist"
fetch_failure_result="$fixture_root/fetch-failure/preparation-result.plist"
git -C "$canonical_clone" remote set-url upstream "$fixture_root/unavailable-upstream.git"
if PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$fetch_failure_manifest" \
    VOICEINK_UPDATE_RESULT_PATH="$fetch_failure_result" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
    > "$fixture_root/fetch-failure.log" 2>&1
then
    printf 'prepare-local-update-test: unavailable upstream was accepted\n' >&2
    exit 1
fi
git -C "$canonical_clone" remote set-url upstream "$upstream_bare"
if [[ "$(/usr/bin/plutil -extract stage raw "$fetch_failure_result" 2>/dev/null || true)" != "fetch" \
    || "$(/usr/bin/plutil -extract forkCommit raw "$fetch_failure_result" 2>/dev/null || true)" != "$candidate_sha" \
    || "$(/usr/bin/plutil -extract upstreamCommit raw "$fetch_failure_result" 2>/dev/null || true)" != "$upstream_sha" ]]
then
    printf 'prepare-local-update-test: fetch failure did not retain known revisions\n' >&2
    exit 1
fi

failure_manifest="$fixture_root/failure/staged-candidate.plist"
failure_result="$fixture_root/failure/preparation-result.plist"
failure_state="$fixture_root/failure/failure-state.plist"
if [[ -f "$xcode_log" ]]; then
    xcode_count_before_failure="$(wc -l < "$xcode_log")"
else
    xcode_count_before_failure=0
fi
if PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    XCODE_SHOULD_FAIL=1 \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$failure_manifest" \
    VOICEINK_UPDATE_RESULT_PATH="$failure_result" \
    VOICEINK_UPDATE_FAILURE_STATE_PATH="$failure_state" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
    > "$fixture_root/failure-first.log" 2>&1
then
    printf 'prepare-local-update-test: deterministic test failure was accepted\n' >&2
    exit 1
fi
xcode_count_after_failure="$(wc -l < "$xcode_log")"
if [[ "$(/usr/bin/plutil -extract stage raw "$failure_result" 2>/dev/null || true)" != "test" \
    || "$(/usr/bin/plutil -extract candidateIdentifier raw "$failure_result" 2>/dev/null || true)" != "$candidate_sha:$upstream_sha" \
    || "$(/usr/bin/plutil -extract repositoryPath raw "$failure_result" 2>/dev/null || true)" != "$canonical_repository_path" \
    || "$(/usr/bin/plutil -extract originRepository raw "$failure_result" 2>/dev/null || true)" != "$fork_bare" \
    || "$(/usr/bin/plutil -extract upstreamRepository raw "$failure_result" 2>/dev/null || true)" != "$upstream_bare" \
    || "$xcode_count_after_failure" -ne $((xcode_count_before_failure + 1)) ]]
then
    printf 'prepare-local-update-test: deterministic failure result was not recorded\n' >&2
    exit 1
fi
/bin/cp "$failure_result" "$failure_state"
/usr/bin/plutil -insert kind -string transient "$failure_state"

set +e
PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    XCODE_SHOULD_FAIL=1 \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$failure_manifest" \
    VOICEINK_UPDATE_RESULT_PATH="$failure_result" \
    VOICEINK_UPDATE_FAILURE_STATE_PATH="$failure_state" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
    > "$fixture_root/failure-transient-retry.log" 2>&1
transient_retry_status=$?
set -e
xcode_count_after_transient_retry="$(wc -l < "$xcode_log")"
if [[ "$transient_retry_status" -eq 0 \
    || "$xcode_count_after_transient_retry" -ne $((xcode_count_after_failure + 1)) ]]
then
    printf 'prepare-local-update-test: persisted transient failure did not retry\n' >&2
    exit 1
fi

/bin/cp "$failure_result" "$failure_state"
/usr/bin/plutil -insert kind -string deterministic "$failure_state"

PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$failure_manifest" \
    VOICEINK_UPDATE_RESULT_PATH="$failure_result" \
    VOICEINK_UPDATE_FAILURE_STATE_PATH="$failure_state" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"
if [[ "$(/usr/bin/plutil -extract outcome raw "$failure_result" 2>/dev/null || true)" != "failureSuppressed" \
    || "$(wc -l < "$xcode_log")" -ne "$xcode_count_after_transient_retry" ]]
then
    printf 'prepare-local-update-test: unchanged deterministic failure reran automatically\n' >&2
    exit 1
fi

PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$failure_manifest" \
    VOICEINK_UPDATE_RESULT_PATH="$failure_result" \
    VOICEINK_UPDATE_FAILURE_STATE_PATH="$failure_state" \
    VOICEINK_UPDATE_RETRY_SUPPRESSED_CANDIDATE=1 \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"
if [[ ! -f "$failure_manifest" || -e "$failure_state" \
    || "$(wc -l < "$xcode_log")" -ne $((xcode_count_after_transient_retry + 2)) ]]
then
    printf 'prepare-local-update-test: explicit retry did not rerun the failed stage\n' >&2
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
if grep -Fq -- 'VoiceInkTests/UpdaterViewModelTests' "$xcode_log"; then
    printf 'prepare-local-update-test: updater tests ran separately from the unit suite\n' >&2
    exit 1
fi
grep -Fq -- '-only-testing:VoiceInkTests test' "$xcode_log"
grep -Fq -- '-configuration Release' "$xcode_log"
grep -Fq -- 'ENABLE_TESTABILITY=YES' "$xcode_log"
grep -Fq -- ' build' "$xcode_log"

stable_signing_config="$fixture_root/stable-signing.gitconfig"
stable_signing_manifest="$fixture_root/stable-signing/staged-candidate.plist"
stable_signing_xcode_log="$fixture_root/stable-signing-xcodebuild.log"
git config --file "$stable_signing_config" voiceink.localCodesignIdentity "VoiceInk Local Development"
stable_signing_hash="1111111111111111111111111111111111111111"

PATH="$fake_bin:$PATH" \
    GIT_CONFIG_GLOBAL="$stable_signing_config" \
    CODESIGNING_IDENTITIES="$stable_signing_hash|VoiceInk Local Development" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$stable_signing_xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$stable_signing_manifest" \
    VOICEINK_UPDATE_RECOVERY_STATE_PATH="$recovery_state" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"

grep -Fq -- "VOICEINK_LOCAL_CODESIGN_IDENTITY=$stable_signing_hash " "$stable_signing_xcode_log"
grep -Fq -- 'CODE_SIGNING_REQUIRED=YES' "$stable_signing_xcode_log"

# Consecutive preparations reuse persistent build caches under the updater's
# directory, run the unit suite (which contains the updater tests) once, and
# keep the Mac from idle-sleeping while they run.
cache_root="$fixture_root/cache"
cache_manifest="$cache_root/staged-candidate.plist"
cache_xcode_log="$fixture_root/cache-xcodebuild.log"
caffeinate_log="$fixture_root/caffeinate.log"
run_cached_preparation() {
    PATH="$fake_bin:$PATH" \
        CANONICAL_PATH="$canonical_clone" \
        XCODE_LOG="$cache_xcode_log" \
        CAFFEINATE_LOG="$caffeinate_log" \
        VOICEINK_REPOSITORY_PATH="$canonical_clone" \
        VOICEINK_UPDATE_MANIFEST_PATH="$cache_manifest" \
        VOICEINK_UPDATE_RECOVERY_STATE_PATH="$recovery_state" \
        /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"
}
run_cached_preparation
first_cache_invocations="$(cut -d '|' -f 2- "$cache_xcode_log")"
run_cached_preparation
if [[ "$(grep -c -- ' test$' "$cache_xcode_log")" -ne 2 \
    || "$(grep -c -- ' build$' "$cache_xcode_log")" -ne 2 \
    || "$(wc -l < "$cache_xcode_log")" -ne 4 ]]
then
    printf 'prepare-local-update-test: a preparation did not run the unit suite exactly once\n' >&2
    exit 1
fi
if [[ "$(cut -d '|' -f 2- "$cache_xcode_log" | sed -n '3,4p')" != "$first_cache_invocations" ]]; then
    printf 'prepare-local-update-test: consecutive preparations used different build caches\n' >&2
    exit 1
fi
while IFS= read -r invocation; do
    [[ "$invocation" == *"-derivedDataPath $cache_root/BuildCache/DerivedData/"* \
        && "$invocation" == *"-clonedSourcePackagesDirPath $cache_root/BuildCache/SourcePackages "* \
        && "$invocation" == *"-packageCachePath $cache_root/BuildCache/PackageCache "* ]] || {
        printf 'prepare-local-update-test: xcodebuild did not use the persistent caches: %s\n' "$invocation" >&2
        exit 1
    }
done < "$cache_xcode_log"
[[ -d "$cache_root/BuildCache/DerivedData/Release/Build/Products/Release/VoiceInk.app" ]] || {
    printf 'prepare-local-update-test: the persistent derived data was discarded\n' >&2
    exit 1
}
[[ ! -e "$cache_root/BuildCache/Worktree" ]]
[[ "$(git -C "$canonical_clone" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]
if [[ "$(grep -c -- '^-i -w [0-9][0-9]*$' "$caffeinate_log" 2>/dev/null || true)" -ne 2 ]]; then
    printf 'prepare-local-update-test: preparation did not prevent idle sleep\n' >&2
    exit 1
fi

# A worktree left by a preparation that was killed is replaced, not reused.
git -C "$canonical_clone" worktree add --detach "$cache_root/BuildCache/Worktree" HEAD >/dev/null 2>&1
printf 'stale\n' > "$cache_root/BuildCache/Worktree/stale-marker"
run_cached_preparation
[[ ! -e "$cache_root/BuildCache/Worktree" ]]
[[ "$(git -C "$canonical_clone" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]

# A checkout killed mid-initialization leaves a locked registration whose
# directory is gone; the next preparation must still be able to add the worktree.
git -C "$canonical_clone" worktree add --detach "$cache_root/BuildCache/Worktree" HEAD >/dev/null 2>&1
git -C "$canonical_clone" worktree lock --reason initializing "$cache_root/BuildCache/Worktree"
rm -rf "$cache_root/BuildCache/Worktree"
run_cached_preparation
[[ ! -e "$cache_root/BuildCache/Worktree" ]]
[[ "$(git -C "$canonical_clone" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]

# Git never waits for a terminal, askpass dialog, or SSH passphrase prompt.
ssh_bin="$fixture_root/ssh-bin"
ssh_log="$fixture_root/ssh.log"
mkdir -p "$ssh_bin"
cat > "$ssh_bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "${GIT_TERMINAL_PROMPT:-unset}" "${GIT_ASKPASS:-unset}" "$*" >> "$SSH_LOG"
exit 255
EOF
chmod +x "$ssh_bin/ssh"
noninteractive_result="$fixture_root/noninteractive/preparation-result.plist"
git -C "$canonical_clone" remote set-url origin "ssh://git@voiceink.invalid/fork.git"
git -C "$canonical_clone" config core.sshCommand "ssh -o ConnectTimeout=7"
if PATH="$ssh_bin:$fake_bin:$PATH" \
    GIT_CONFIG_GLOBAL=/dev/null \
    SSH_LOG="$ssh_log" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$fixture_root/noninteractive/staged-candidate.plist" \
    VOICEINK_UPDATE_RESULT_PATH="$noninteractive_result" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
    > "$fixture_root/noninteractive-output.log" 2>&1 < /dev/null
then
    git -C "$canonical_clone" config --unset core.sshCommand
    git -C "$canonical_clone" remote set-url origin "$fork_bare"
    printf 'prepare-local-update-test: unreachable SSH origin was accepted\n' >&2
    exit 1
fi
git -C "$canonical_clone" remote set-url origin "$fork_bare"
git -C "$canonical_clone" config --unset core.sshCommand
if ! grep -Eq '^0\|/usr/bin/false\|.*BatchMode=yes' "$ssh_log" \
    || ! grep -Fq -- "-o ConnectTimeout=7 -o BatchMode=yes" "$ssh_log" \
    || [[ "$(/usr/bin/plutil -extract stage raw "$noninteractive_result" 2>/dev/null || true)" != "fetch" ]]
then
    printf 'prepare-local-update-test: git fetch could prompt for credentials\n' >&2
    exit 1
fi

# The candidate must be signed by the identity that signed the installed app,
# or macOS revokes VoiceInk's permissions after installation. Check before
# building, and name both identities and the fix.
installed_bundle="$fixture_root/installed/VoiceInk.app"
mkdir -p "$installed_bundle/Contents"
installed_leaf="installed leaf certificate"
installed_leaf_hash="$(printf '%s' "$installed_leaf" | shasum -a 1 | awk '{ print toupper($1) }')"
identity_manifest="$fixture_root/identity-mismatch/staged-candidate.plist"
identity_result="$fixture_root/identity-mismatch/preparation-result.plist"
xcode_lines_before_identity="$(wc -l < "$xcode_log")"
if PATH="$fake_bin:$PATH" \
    GIT_CONFIG_GLOBAL=/dev/null \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    INSTALLED_SIGNATURE_DETAILS='Executable=VoiceInk\nAuthority=VoiceInk Local Development\nAuthority=VoiceInk Local Root' \
    INSTALLED_LEAF_CERTIFICATE="$installed_leaf" \
    VOICEINK_INSTALLED_BUNDLE_PATH="$installed_bundle" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$identity_manifest" \
    VOICEINK_UPDATE_RESULT_PATH="$identity_result" \
    VOICEINK_UPDATE_RECOVERY_STATE_PATH="$recovery_state" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
    > "$fixture_root/identity-mismatch.log" 2>&1
then
    printf 'prepare-local-update-test: mismatched signing identity was accepted\n' >&2
    exit 1
fi
identity_message="$(/usr/bin/plutil -extract message raw "$identity_result" 2>/dev/null || true)"
if [[ "$(/usr/bin/plutil -extract stage raw "$identity_result" 2>/dev/null || true)" != "preflight" \
    || "$(/usr/bin/plutil -extract kind raw "$identity_result" 2>/dev/null || true)" != "deterministic" \
    || "$identity_message" != *"ad-hoc"* \
    || "$identity_message" != *"VoiceInk Local Development"* \
    || "$identity_message" != *"git config --global voiceink.localCodesignIdentity $installed_leaf_hash"* \
    || "$(wc -l < "$xcode_log")" -ne "$xcode_lines_before_identity" \
    || -e "$identity_manifest" ]]
then
    printf 'prepare-local-update-test: identity mismatch did not fail at preflight: %s\n' "$identity_message" >&2
    exit 1
fi
[[ "$(git -C "$canonical_clone" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]

hash_identity_config="$fixture_root/hash-identity.gitconfig"
git config --file "$hash_identity_config" voiceink.localCodesignIdentity "$installed_leaf_hash"
hash_identity_manifest="$fixture_root/identity-hash/staged-candidate.plist"
PATH="$fake_bin:$PATH" \
    GIT_CONFIG_GLOBAL="$hash_identity_config" \
    CODESIGNING_IDENTITIES="$installed_leaf_hash|VoiceInk Local Development" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    INSTALLED_SIGNATURE_DETAILS='Authority=VoiceInk Local Development' \
    INSTALLED_LEAF_CERTIFICATE="$installed_leaf" \
    VOICEINK_INSTALLED_BUNDLE_PATH="$installed_bundle" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$hash_identity_manifest" \
    VOICEINK_UPDATE_RECOVERY_STATE_PATH="$recovery_state" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"
[[ -f "$hash_identity_manifest" ]]

# A name selector resolves to the certificate it names in the keychain, and
# that certificate's fingerprint is what is compared and handed to xcodebuild.
name_identity_manifest="$fixture_root/identity-name/staged-candidate.plist"
name_identity_xcode_log="$fixture_root/identity-name-xcodebuild.log"
PATH="$fake_bin:$PATH" \
    GIT_CONFIG_GLOBAL="$stable_signing_config" \
    CODESIGNING_IDENTITIES="0000000000000000000000000000000000000001|Apple Development: Someone Else\n$installed_leaf_hash|VoiceInk Local Development" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$name_identity_xcode_log" \
    INSTALLED_SIGNATURE_DETAILS='Authority=VoiceInk Local Development' \
    INSTALLED_LEAF_CERTIFICATE="$installed_leaf" \
    VOICEINK_INSTALLED_BUNDLE_PATH="$installed_bundle" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$name_identity_manifest" \
    VOICEINK_UPDATE_RECOVERY_STATE_PATH="$recovery_state" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"
[[ -f "$name_identity_manifest" ]]
grep -Fq -- "VOICEINK_LOCAL_CODESIGN_IDENTITY=$installed_leaf_hash " "$name_identity_xcode_log"

# A replacement certificate that only shares the installed certificate's name
# is a different identity to macOS, so it fails at preflight.
replacement_hash="2222222222222222222222222222222222222222"
replacement_manifest="$fixture_root/identity-replacement/staged-candidate.plist"
replacement_result="$fixture_root/identity-replacement/preparation-result.plist"
xcode_lines_before_replacement="$(wc -l < "$xcode_log")"
if PATH="$fake_bin:$PATH" \
    GIT_CONFIG_GLOBAL="$stable_signing_config" \
    CODESIGNING_IDENTITIES="$replacement_hash|VoiceInk Local Development" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    INSTALLED_SIGNATURE_DETAILS='Authority=VoiceInk Local Development' \
    INSTALLED_LEAF_CERTIFICATE="$installed_leaf" \
    VOICEINK_INSTALLED_BUNDLE_PATH="$installed_bundle" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$replacement_manifest" \
    VOICEINK_UPDATE_RESULT_PATH="$replacement_result" \
    VOICEINK_UPDATE_RECOVERY_STATE_PATH="$recovery_state" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
    > "$fixture_root/identity-replacement.log" 2>&1
then
    printf 'prepare-local-update-test: a same-name replacement certificate was accepted\n' >&2
    exit 1
fi
replacement_message="$(/usr/bin/plutil -extract message raw "$replacement_result" 2>/dev/null || true)"
if [[ "$(/usr/bin/plutil -extract stage raw "$replacement_result" 2>/dev/null || true)" != "preflight" \
    || "$replacement_message" != *"$replacement_hash"* \
    || "$replacement_message" != *"$installed_leaf_hash"* \
    || "$(wc -l < "$xcode_log")" -ne "$xcode_lines_before_replacement" \
    || -e "$replacement_manifest" ]]
then
    printf 'prepare-local-update-test: same-name replacement did not fail at preflight: %s\n' "$replacement_message" >&2
    exit 1
fi

# A selector that matches several certificates cannot say which one signs the
# candidate, so it fails at preflight and lists them.
ambiguous_manifest="$fixture_root/identity-ambiguous/staged-candidate.plist"
ambiguous_result="$fixture_root/identity-ambiguous/preparation-result.plist"
if PATH="$fake_bin:$PATH" \
    GIT_CONFIG_GLOBAL="$stable_signing_config" \
    CODESIGNING_IDENTITIES="$installed_leaf_hash|VoiceInk Local Development\n$replacement_hash|VoiceInk Local Development (2)" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    INSTALLED_SIGNATURE_DETAILS='Authority=VoiceInk Local Development' \
    INSTALLED_LEAF_CERTIFICATE="$installed_leaf" \
    VOICEINK_INSTALLED_BUNDLE_PATH="$installed_bundle" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$ambiguous_manifest" \
    VOICEINK_UPDATE_RESULT_PATH="$ambiguous_result" \
    VOICEINK_UPDATE_RECOVERY_STATE_PATH="$recovery_state" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
    > "$fixture_root/identity-ambiguous.log" 2>&1
then
    printf 'prepare-local-update-test: an ambiguous signing identity was accepted\n' >&2
    exit 1
fi
ambiguous_message="$(/usr/bin/plutil -extract message raw "$ambiguous_result" 2>/dev/null || true)"
if [[ "$(/usr/bin/plutil -extract stage raw "$ambiguous_result" 2>/dev/null || true)" != "preflight" \
    || "$(/usr/bin/plutil -extract kind raw "$ambiguous_result" 2>/dev/null || true)" != "deterministic" \
    || "$ambiguous_message" != *"matches 2 certificates"* \
    || "$ambiguous_message" != *"$installed_leaf_hash"* \
    || "$ambiguous_message" != *"$replacement_hash"* \
    || "$(wc -l < "$xcode_log")" -ne "$xcode_lines_before_replacement" \
    || -e "$ambiguous_manifest" ]]
then
    printf 'prepare-local-update-test: ambiguous identity did not fail at preflight: %s\n' "$ambiguous_message" >&2
    exit 1
fi
[[ "$(git -C "$canonical_clone" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]

# Preparation prunes orphaned candidate references and stage directories that
# are older than the retention window and not contained in the fork's main.
# The staged (or retained-for-publication) candidate and recent or published
# candidates stay.
prune_root="$fixture_root/prune"
prune_manifest="$prune_root/staged-candidate.plist"
orphan_sha="$(git -C "$canonical_clone" commit-tree -p "$before_head" -m "test: orphaned candidate" "$before_head^{tree}")"
retained_sha="$(git -C "$canonical_clone" commit-tree -p "$before_head" -m "test: retained candidate" "$before_head^{tree}")"
recent_epoch="$(date +%s)"
old_orphan_name="$orphan_sha-1000-1"
recent_orphan_name="$orphan_sha-$recent_epoch-2"
old_published_name="$before_head-1000-3"
retained_name="$retained_sha-1000-4"
for candidate_name in "$old_orphan_name" "$recent_orphan_name" "$old_published_name" "$retained_name"; do
    git -C "$canonical_clone" update-ref "refs/voiceink-updater/candidates/$candidate_name" "${candidate_name%%-*}"
    mkdir -p "$prune_root/candidates/$candidate_name/VoiceInk.app"
done
/usr/bin/plutil -create xml1 "$prune_manifest"
/usr/bin/plutil -insert forkCommit -string "$retained_sha" "$prune_manifest"
/usr/bin/plutil -insert forkBaseCommit -string "$before_head" "$prune_manifest"
/usr/bin/plutil -insert upstreamCommit -string "$upstream_sha" "$prune_manifest"
/usr/bin/plutil -insert bundlePath -string "$prune_root/candidates/$retained_name/VoiceInk.app" "$prune_manifest"
/usr/bin/plutil -insert preparedAt -date "2000-01-01T00:00:00Z" "$prune_manifest"
/usr/bin/plutil -insert candidateRef -string "refs/voiceink-updater/candidates/$retained_name" "$prune_manifest"
PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$prune_manifest" \
    VOICEINK_UPDATE_RESULT_PATH="$prune_root/preparation-result.plist" \
    VOICEINK_UPDATE_DEFER_BUILD=1 \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"
if git -C "$canonical_clone" rev-parse --verify --quiet "refs/voiceink-updater/candidates/$old_orphan_name" >/dev/null \
    || [[ -e "$prune_root/candidates/$old_orphan_name" ]]
then
    printf 'prepare-local-update-test: an expired orphaned candidate was not pruned\n' >&2
    exit 1
fi
for candidate_name in "$recent_orphan_name" "$old_published_name" "$retained_name"; do
    if ! git -C "$canonical_clone" rev-parse --verify --quiet "refs/voiceink-updater/candidates/$candidate_name" >/dev/null \
        || [[ ! -d "$prune_root/candidates/$candidate_name/VoiceInk.app" ]]
    then
        printf 'prepare-local-update-test: protected candidate %s was pruned\n' "$candidate_name" >&2
        exit 1
    fi
    git -C "$canonical_clone" update-ref -d "refs/voiceink-updater/candidates/$candidate_name"
done
[[ -f "$prune_manifest" ]]

# Terminating the helper's process group (the in-app watchdog or Cancel)
# stops a hung build and still removes the worktree and temporary files.
hang_root="$fixture_root/hang"
hang_temporary="$fixture_root/hang-tmp"
hang_marker="$fixture_root/hang-started"
mkdir -p "$hang_root" "$hang_temporary"
set -m
PATH="$fake_bin:$PATH" \
    TMPDIR="$hang_temporary" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$fixture_root/hang-xcodebuild.log" \
    XCODE_HANG_MARKER="$hang_marker" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$hang_root/staged-candidate.plist" \
    VOICEINK_UPDATE_RECOVERY_STATE_PATH="$recovery_state" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
    > "$fixture_root/hang-output.log" 2>&1 &
hang_pid=$!
set +m
for _ in $(seq 1 200); do
    [[ -f "$hang_marker" ]] && break
    sleep 0.1
done
if [[ ! -f "$hang_marker" ]]; then
    kill -KILL -- "-$hang_pid" 2>/dev/null || true
    printf 'prepare-local-update-test: hung build fixture never started\n' >&2
    exit 1
fi
[[ -d "$hang_root/BuildCache/Worktree" ]]
kill -TERM -- "-$hang_pid"
hang_stopped=false
for _ in $(seq 1 100); do
    if ! kill -0 "$hang_pid" 2>/dev/null; then
        hang_stopped=true
        break
    fi
    sleep 0.1
done
if [[ "$hang_stopped" != true ]]; then
    kill -KILL -- "-$hang_pid" 2>/dev/null || true
    printf 'prepare-local-update-test: terminated preparation kept running\n' >&2
    exit 1
fi
if wait "$hang_pid"; then
    printf 'prepare-local-update-test: terminated preparation reported success\n' >&2
    exit 1
fi
if [[ -e "$hang_root/BuildCache/Worktree" \
    || -n "$(ls -A "$hang_temporary")" \
    || -e "$hang_root/staged-candidate.plist" \
    || "$(git -C "$canonical_clone" worktree list --porcelain | grep -c '^worktree ')" -ne 1 ]]
then
    printf 'prepare-local-update-test: terminated preparation left its worktree or temporary files\n' >&2
    exit 1
fi

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

# A healthy installed candidate whose publication did not finish is retained.
# The next preparation run publishes it without rebuilding. Use a copy of the
# staged candidate so the shared fixture state stays intact for later cases.
retry_root="$fixture_root/publication-retry"
retry_manifest="$retry_root/staged-candidate.plist"
retry_result="$retry_root/preparation-result.plist"
retry_stage="$retry_root/candidates/$upstream_fast_forward_sha-1-1"
retry_ref="refs/voiceink-updater/candidates/$upstream_fast_forward_sha-1-1"
mkdir -p "$retry_stage"
/usr/bin/ditto "$fast_forward_staged_bundle" "$retry_stage/VoiceInk.app"
cp "$fast_forward_manifest" "$retry_manifest"
/usr/bin/plutil -replace bundlePath -string "$retry_stage/VoiceInk.app" "$retry_manifest"
/usr/bin/plutil -replace candidateRef -string "$retry_ref" "$retry_manifest"
git -C "$canonical_clone" update-ref "$retry_ref" "$upstream_fast_forward_sha"
xcode_lines_before_retry="$(wc -l < "$xcode_log")"

run_publication_retry() {
    PATH="$fake_bin:$PATH" \
        CANONICAL_PATH="$canonical_clone" \
        XCODE_LOG="$xcode_log" \
        VOICEINK_REPOSITORY_PATH="$canonical_clone" \
        VOICEINK_UPDATE_MANIFEST_PATH="$retry_manifest" \
        VOICEINK_UPDATE_RESULT_PATH="$retry_result" \
        VOICEINK_INSTALLED_FORK_COMMIT="$upstream_fast_forward_sha" \
        /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"
}

# Local main that cannot fast-forward keeps the candidate pending.
git -C "$canonical_clone" switch --detach "$before_head" >/dev/null 2>&1
diverged_local_sha="$(git -C "$canonical_clone" commit-tree -p "$before_head" -m "test: diverge local main" "$before_head^{tree}")"
git -C "$canonical_clone" update-ref refs/heads/main "$diverged_local_sha" "$before_head"
if run_publication_retry > "$retry_root/diverged-output.log" 2>&1; then
    printf 'prepare-local-update-test: diverged local main published the retained candidate\n' >&2
    exit 1
fi
[[ "$(/usr/bin/plutil -extract outcome raw "$retry_result")" == "failure" ]]
[[ "$(/usr/bin/plutil -extract stage raw "$retry_result")" == "publication" ]]
[[ "$(/usr/bin/plutil -extract kind raw "$retry_result")" == "transient" ]]
grep -Fq "Local main cannot fast-forward to the installed update" "$retry_root/diverged-output.log"
[[ "$(git --git-dir="$fork_bare" rev-parse refs/heads/main)" == "$candidate_sha" ]]
[[ -f "$retry_manifest" && -d "$retry_stage/VoiceInk.app" ]]
[[ "$(git -C "$canonical_clone" rev-parse "$retry_ref")" == "$upstream_fast_forward_sha" ]]
git -C "$canonical_clone" update-ref refs/heads/main "$before_head" "$diverged_local_sha"
git -C "$canonical_clone" switch main >/dev/null 2>&1

run_publication_retry
[[ "$(/usr/bin/plutil -extract outcome raw "$retry_result")" == "upToDate" ]]
[[ "$(git --git-dir="$fork_bare" rev-parse refs/heads/main)" == "$upstream_fast_forward_sha" ]]
[[ "$(git -C "$canonical_clone" rev-parse refs/heads/main)" == "$upstream_fast_forward_sha" ]]
[[ "$(git -C "$canonical_clone" status --porcelain)" == "" ]]
[[ ! -e "$retry_manifest" && ! -e "$retry_stage" ]]
if git -C "$canonical_clone" rev-parse --verify --quiet "$retry_ref" >/dev/null; then
    printf 'prepare-local-update-test: published candidate reference was not cleaned up\n' >&2
    exit 1
fi
[[ "$(wc -l < "$xcode_log")" -eq "$xcode_lines_before_retry" ]]
[[ "$(git -C "$canonical_clone" rev-parse "$fast_forward_candidate_ref")" == "$upstream_fast_forward_sha" ]]

# Origin already has the installed candidate but local main did not converge.
# The retry must still advance local main before it drops the retained state.
git -C "$canonical_clone" reset --hard --quiet "$before_head"
mkdir -p "$retry_stage"
/usr/bin/ditto "$fast_forward_staged_bundle" "$retry_stage/VoiceInk.app"
cp "$fast_forward_manifest" "$retry_manifest"
/usr/bin/plutil -replace bundlePath -string "$retry_stage/VoiceInk.app" "$retry_manifest"
/usr/bin/plutil -replace candidateRef -string "$retry_ref" "$retry_manifest"
git -C "$canonical_clone" update-ref "$retry_ref" "$upstream_fast_forward_sha"
run_publication_retry
[[ "$(/usr/bin/plutil -extract outcome raw "$retry_result")" == "upToDate" ]]
[[ "$(git -C "$canonical_clone" rev-parse refs/heads/main)" == "$upstream_fast_forward_sha" ]]
[[ ! -e "$retry_manifest" && ! -e "$retry_stage" ]]
if git -C "$canonical_clone" rev-parse --verify --quiet "$retry_ref" >/dev/null; then
    printf 'prepare-local-update-test: converged candidate reference was not cleaned up\n' >&2
    exit 1
fi

git --git-dir="$fork_bare" update-ref refs/heads/main "$candidate_sha" "$upstream_fast_forward_sha"
git -C "$canonical_clone" reset --hard --quiet "$before_head"
git -C "$canonical_clone" fetch --quiet origin main

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

# A retained merge candidate is identified from its manifest, because a
# recomputed merge commit gets a different SHA one second later.
sleep 1
merge_retry_result="$fixture_root/merge/publication-retry-result.plist"
xcode_lines_before_merge_retry="$(wc -l < "$xcode_log")"
PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$merge_manifest" \
    VOICEINK_UPDATE_RESULT_PATH="$merge_retry_result" \
    VOICEINK_INSTALLED_FORK_COMMIT="$merge_candidate_sha" \
    /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh"
[[ "$(/usr/bin/plutil -extract outcome raw "$merge_retry_result")" == "upToDate" ]]
[[ "$(/usr/bin/plutil -extract forkCommit raw "$merge_retry_result")" == "$merge_candidate_sha" ]]
[[ "$(git --git-dir="$fork_bare" rev-parse refs/heads/main)" == "$merge_candidate_sha" ]]
[[ "$(git -C "$canonical_clone" rev-parse refs/heads/main)" == "$merge_candidate_sha" ]]
[[ ! -e "$merge_manifest" ]]
[[ "$(wc -l < "$xcode_log")" -eq "$xcode_lines_before_merge_retry" ]]
git --git-dir="$fork_bare" update-ref refs/heads/main "$diverged_fork_sha" "$merge_candidate_sha"
git -C "$canonical_clone" reset --hard --quiet "$before_head"
git -C "$canonical_clone" fetch --quiet origin main

printf 'fork-conflict\n' > "$fork_writer/README.md"
git -C "$fork_writer" add README.md
git -C "$fork_writer" commit -m "feat: change fork readme" >/dev/null
git -C "$fork_writer" push origin main >/dev/null
printf 'upstream-conflict\n' > "$seed_clone/README.md"
git -C "$seed_clone" add README.md
git -C "$seed_clone" commit -m "feat: change upstream readme" >/dev/null
git -C "$seed_clone" push upstream main >/dev/null
conflict_manifest="$fixture_root/conflict/staged-candidate.plist"
conflict_result="$fixture_root/conflict/preparation-result.plist"

if PATH="$fake_bin:$PATH" \
    CANONICAL_PATH="$canonical_clone" \
    XCODE_LOG="$xcode_log" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_MANIFEST_PATH="$conflict_manifest" \
    VOICEINK_UPDATE_RESULT_PATH="$conflict_result" \
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
if [[ "$(/usr/bin/plutil -extract stage raw "$conflict_result" 2>/dev/null || true)" != "merge" \
    || "$(/usr/bin/plutil -extract repositoryPath raw "$conflict_result" 2>/dev/null || true)" != "$canonical_repository_path" \
    || "$(/usr/bin/plutil -extract originRepository raw "$conflict_result" 2>/dev/null || true)" != "$fork_bare" \
    || "$(/usr/bin/plutil -extract upstreamRepository raw "$conflict_result" 2>/dev/null || true)" != "$upstream_bare" \
    || "$(/usr/bin/plutil -extract conflicts.0 raw "$conflict_result" 2>/dev/null || true)" != "README.md" ]]
then
    printf 'prepare-local-update-test: merge conflict context was incomplete\n' >&2
    exit 1
fi
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
