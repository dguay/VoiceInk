#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/voiceink-install-update-test.XXXXXX")"
parent_pid=""
launched_pid=""

cleanup() {
    if [[ -n "$parent_pid" ]]; then
        kill "$parent_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$launched_pid" ]]; then
        kill "$launched_pid" >/dev/null 2>&1 || true
    fi
    rm -rf "$fixture_root"
}
trap cleanup EXIT

fork_bare="$fixture_root/fork.git"
seed_clone="$fixture_root/seed"
canonical_clone="$fixture_root/canonical"
git init --bare --initial-branch=main "$fork_bare" >/dev/null
git init --initial-branch=main "$seed_clone" >/dev/null
git -C "$seed_clone" config user.name "VoiceInk Installer Test"
git -C "$seed_clone" config user.email "installer-test@example.com"
printf 'old\n' > "$seed_clone/version"
git -C "$seed_clone" add version
git -C "$seed_clone" commit -m "test: seed installed candidate" >/dev/null
git -C "$seed_clone" remote add origin "$fork_bare"
git -C "$seed_clone" push -u origin main >/dev/null
old_sha="$(git -C "$seed_clone" rev-parse HEAD)"
upstream_sha="$old_sha"
git clone "$fork_bare" "$canonical_clone" >/dev/null

printf 'new\n' > "$seed_clone/version"
git -C "$seed_clone" add version
git -C "$seed_clone" commit -m "test: publish newer candidate" >/dev/null
git -C "$seed_clone" push origin main >/dev/null
new_sha="$(git -C "$seed_clone" rev-parse HEAD)"

installed_bundle="$fixture_root/Applications/VoiceInk.app"
staged_bundle="$fixture_root/staging/candidates/$new_sha/VoiceInk.app"
manifest_path="$fixture_root/staging/staged-candidate.plist"
recovery_root="$fixture_root/recovery"
backup_bundle="$recovery_root/VoiceInk.app"
application_support="$fixture_root/Library/Application Support/com.prakashjoshipax.VoiceInk"
preferences="$fixture_root/Library/Preferences/com.prakashjoshipax.VoiceInk.plist"

mkdir -p "$installed_bundle/Contents" "$staged_bundle/Contents"
mkdir -p "$application_support" "$(dirname "$preferences")"
printf 'installed-before-update\n' > "$installed_bundle/Contents/version"
printf 'newer-candidate\n' > "$staged_bundle/Contents/version"
printf 'state-before-update\n' > "$application_support/state"
printf 'preferences-before-update\n' > "$preferences"

/usr/bin/plutil -create xml1 "$staged_bundle/Contents/Info.plist"
/usr/bin/plutil -insert VoiceInkForkCommit -string "$new_sha" "$staged_bundle/Contents/Info.plist"
/usr/bin/plutil -insert VoiceInkUpstreamCommit -string "$upstream_sha" "$staged_bundle/Contents/Info.plist"
/usr/bin/plutil -insert VoiceInkUpdaterKind -string fork "$staged_bundle/Contents/Info.plist"

/usr/bin/plutil -create xml1 "$installed_bundle/Contents/Info.plist"
/usr/bin/plutil -insert VoiceInkForkCommit -string "$old_sha" "$installed_bundle/Contents/Info.plist"
/usr/bin/plutil -insert VoiceInkUpstreamCommit -string "$upstream_sha" "$installed_bundle/Contents/Info.plist"
/usr/bin/plutil -insert VoiceInkUpdaterKind -string fork "$installed_bundle/Contents/Info.plist"

/usr/bin/plutil -create xml1 "$manifest_path"
/usr/bin/plutil -insert forkCommit -string "$new_sha" "$manifest_path"
/usr/bin/plutil -insert upstreamCommit -string "$upstream_sha" "$manifest_path"
/usr/bin/plutil -insert bundlePath -string "$staged_bundle" "$manifest_path"
/usr/bin/plutil -insert preparedAt -date "2026-08-22T12:00:00Z" "$manifest_path"

sleep 30 &
parent_pid=$!

set +e
/bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$old_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/stale-output.log" 2>&1
status=$?
set -e

[[ "$status" -eq 75 ]]
kill -0 "$parent_pid"
[[ "$(< "$installed_bundle/Contents/version")" == "installed-before-update" ]]
[[ ! -e "$backup_bundle" ]]
grep -Fq "approved candidate is no longer staged" "$fixture_root/stale-output.log"

staged_bundle="$fixture_root/staging/candidates/$old_sha/VoiceInk.app"
mkdir -p "$staged_bundle/Contents"
printf 'approved-but-stale\n' > "$staged_bundle/Contents/version"
/usr/bin/plutil -create xml1 "$staged_bundle/Contents/Info.plist"
/usr/bin/plutil -insert VoiceInkForkCommit -string "$old_sha" "$staged_bundle/Contents/Info.plist"
/usr/bin/plutil -insert VoiceInkUpstreamCommit -string "$upstream_sha" "$staged_bundle/Contents/Info.plist"
/usr/bin/plutil -insert VoiceInkUpdaterKind -string fork "$staged_bundle/Contents/Info.plist"
/usr/bin/plutil -replace forkCommit -string "$old_sha" "$manifest_path"
/usr/bin/plutil -replace bundlePath -string "$staged_bundle" "$manifest_path"

set +e
VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$old_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/origin-stale-output.log" 2>&1
origin_stale_status=$?
set -e

[[ "$origin_stale_status" -eq 75 ]]
kill -0 "$parent_pid"
[[ "$(< "$installed_bundle/Contents/version")" == "installed-before-update" ]]
[[ ! -e "$backup_bundle" ]]
[[ ! -e "$manifest_path" ]]
[[ ! -e "$staged_bundle" ]]
grep -Fq "origin/main changed after preparation" "$fixture_root/origin-stale-output.log"

staged_bundle="$fixture_root/staging/candidates/$new_sha/VoiceInk.app"
/usr/bin/plutil -create xml1 "$manifest_path"
/usr/bin/plutil -insert forkCommit -string "$new_sha" "$manifest_path"
/usr/bin/plutil -insert upstreamCommit -string "$upstream_sha" "$manifest_path"
/usr/bin/plutil -insert bundlePath -string "$staged_bundle" "$manifest_path"
/usr/bin/plutil -insert preparedAt -date "2026-08-22T12:00:00Z" "$manifest_path"

fake_bin="$fixture_root/bin"
health_path="$fixture_root/staging/health.plist"
launch_log="$fixture_root/launch.log"
mkdir -p "$fake_bin"

cat > "$fake_bin/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -d "${@: -1}" ]]
[[ "${CODESIGN_SHOULD_FAIL:-0}" != 1 ]]
EOF

cat > "$fake_bin/launch-voiceink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

bundle_path="$1"
health_path="$2"
info_plist="$bundle_path/Contents/Info.plist"
/bin/sleep 30 >/dev/null 2>&1 &
app_pid=$!

if [[ "${VOICEINK_TEST_SKIP_HEALTH:-0}" != 1 ]]; then
    /usr/bin/plutil -create xml1 "$health_path"
    /usr/bin/plutil -insert forkCommit -string "${VOICEINK_TEST_HEALTH_FORK_OVERRIDE:-$(/usr/bin/plutil -extract VoiceInkForkCommit raw "$info_plist")}" "$health_path"
    /usr/bin/plutil -insert upstreamCommit -string "$(/usr/bin/plutil -extract VoiceInkUpstreamCommit raw "$info_plist")" "$health_path"
    /usr/bin/plutil -insert updaterKind -string "$(/usr/bin/plutil -extract VoiceInkUpdaterKind raw "$info_plist")" "$health_path"
    /usr/bin/plutil -insert processIdentifier -integer "$app_pid" "$health_path"
    /usr/bin/plutil -insert permissionState -dictionary "$health_path"
    /usr/bin/plutil -insert permissionState.microphoneAuthorized -bool "${VOICEINK_TEST_MICROPHONE_AUTHORIZED:-true}" "$health_path"
    /usr/bin/plutil -insert permissionState.accessibilityAuthorized -bool "${VOICEINK_TEST_ACCESSIBILITY_AUTHORIZED:-true}" "$health_path"
    /usr/bin/plutil -insert permissionState.screenCaptureAuthorized -bool "${VOICEINK_TEST_SCREEN_CAPTURE_AUTHORIZED:-true}" "$health_path"
fi
if [[ -n "${VOICEINK_TEST_PID_LOG:-}" ]]; then
    printf '%s\n' "$app_pid" > "$VOICEINK_TEST_PID_LOG"
fi
if [[ -n "${VOICEINK_TEST_MUTATE_APPLICATION_SUPPORT:-}" ]]; then
    printf 'candidate-data\n' > "$VOICEINK_TEST_MUTATE_APPLICATION_SUPPORT/state"
fi
if [[ -n "${VOICEINK_TEST_MUTATE_PREFERENCES:-}" ]]; then
    printf 'candidate-preferences\n' > "$VOICEINK_TEST_MUTATE_PREFERENCES"
fi
printf '%s\n' "$bundle_path" >> "$VOICEINK_TEST_LAUNCH_LOG"
printf '%s\n' "$app_pid"
EOF

cat > "$fake_bin/relaunch-voiceink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'rollback:%s\n' "$1" >> "$VOICEINK_TEST_LAUNCH_LOG"
if [[ -n "${VOICEINK_TEST_OUTCOME_ORDER_LOG:-}" ]]; then
    printf 'relaunch\n' >> "$VOICEINK_TEST_OUTCOME_ORDER_LOG"
fi
EOF

cat > "$fake_bin/record-outcome" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cp "$1" "$VOICEINK_TEST_OUTCOME_REPORT"
rm "$1"
if [[ -n "${VOICEINK_TEST_OUTCOME_ORDER_LOG:-}" ]]; then
    printf 'outcome\n' >> "$VOICEINK_TEST_OUTCOME_ORDER_LOG"
fi
EOF

cat > "$fake_bin/fail-relaunch" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF

cat > "$fake_bin/fail-snapshot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF

cat > "$fake_bin/restore-preferences" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
/bin/cp "$1" "$2"
EOF

cat > "$fake_bin/restore-credentials" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'restored:%s\n' "$1" > "$VOICEINK_TEST_CREDENTIAL_LOG"
EOF

cat > "$fake_bin/create-credentials" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" =~ ^[0-9a-f-]{36}$ ]]
printf '%s\n' "$1" > "$VOICEINK_TEST_CREDENTIAL_CREATE_LOG"
EOF

cat > "$fake_bin/delete-credentials" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "$VOICEINK_TEST_CREDENTIAL_DELETE_LOG"
EOF

cat > "$fake_bin/mutate-then-fail-replacement" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mv "$1" "$3"
mv "$2" "$1"
printf '%s\n' "$(< "$1/Contents/version")" > "$VOICEINK_TEST_MUTATION_LOG"
exit 1
EOF

cat > "$fake_bin/replace-bundle" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mv "$1" "$3"
mv "$2" "$1"
EOF

cat > "$fake_bin/fail-replacement" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF

cat > "$fake_bin/fail-pending-recovery-move" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == *.pending && ! -f "$VOICEINK_TEST_RECOVERY_MOVE_FAILED" ]]; then
    : > "$VOICEINK_TEST_RECOVERY_MOVE_FAILED"
    exit 1
fi
mv "$1" "$2"
EOF

cat > "$fake_bin/git-with-late-update" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ " $* " == *" fetch origin main "* ]]; then
    count=0
    if [[ -f "$VOICEINK_TEST_FETCH_COUNT" ]]; then
        count="$(< "$VOICEINK_TEST_FETCH_COUNT")"
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$VOICEINK_TEST_FETCH_COUNT"
    if [[ "$count" -eq 2 ]]; then
        printf 'newest\n' > "$VOICEINK_TEST_SEED_CLONE/version"
        /usr/bin/git -C "$VOICEINK_TEST_SEED_CLONE" add version
        /usr/bin/git -C "$VOICEINK_TEST_SEED_CLONE" commit -m "test: publish during restart" >/dev/null
        /usr/bin/git -C "$VOICEINK_TEST_SEED_CLONE" push origin main >/dev/null
    fi
fi

exec /usr/bin/git "$@"
EOF

cat > "$fake_bin/git-require-health-before-push" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ " $* " == *" fetch origin main "* \
    && -n "${VOICEINK_TEST_PUSH_COMPLETED_PATH:-}" \
    && -f "$VOICEINK_TEST_PUSH_COMPLETED_PATH" ]]
then
    printf 'unexpected fetch after successful push\n' >&2
    exit 86
fi

if [[ " $* " == *" fetch origin main "* \
    && -n "${VOICEINK_TEST_AMBIGUOUS_PUSH_PATH:-}" \
    && -f "$VOICEINK_TEST_AMBIGUOUS_PUSH_PATH" ]]
then
    printf 'simulated reconciliation network failure\n' >&2
    exit 86
fi

if [[ " $* " == *" fetch origin main "* \
    && -n "${VOICEINK_TEST_REQUIRED_HEALTH_PATH:-}" \
    && -f "$VOICEINK_TEST_REQUIRED_HEALTH_PATH" ]]
then
    if [[ "${VOICEINK_TEST_FAIL_FETCH_AFTER_HEALTH:-0}" == 1 ]]; then
        printf 'simulated post-health network failure\n' >&2
        exit 86
    fi
    if [[ -n "${VOICEINK_TEST_DIRTY_AFTER_HEALTH_PATH:-}" ]]; then
        printf 'edited during installation\n' > "$VOICEINK_TEST_DIRTY_AFTER_HEALTH_PATH"
    fi
fi

if [[ " $* " == *" push origin "* && " $* " == *":refs/heads/main "* ]]; then
    [[ " $* " != *" --force"* ]]
    [[ -f "$VOICEINK_TEST_REQUIRED_HEALTH_PATH" ]]
    [[ "$(/usr/bin/plutil -extract forkCommit raw "$VOICEINK_TEST_REQUIRED_HEALTH_PATH")" == "$VOICEINK_TEST_REQUIRED_PUBLISH_SHA" ]]
    if [[ -n "${VOICEINK_TEST_EXPECTED_LOCAL_MAIN_BEFORE_PUSH:-}" ]]; then
        [[ "$(/usr/bin/git -C "$VOICEINK_REPOSITORY_PATH" rev-parse refs/heads/main)" \
            == "$VOICEINK_TEST_EXPECTED_LOCAL_MAIN_BEFORE_PUSH" ]]
    fi
    printf 'push-after-health\n' >> "$VOICEINK_TEST_PUBLISH_LOG"
    if [[ -n "${VOICEINK_TEST_PEER_CLONE:-}" \
        && -n "${VOICEINK_TEST_PEER_PUSHED_PATH:-}" \
        && ! -f "$VOICEINK_TEST_PEER_PUSHED_PATH" ]]
    then
        /usr/bin/git -C "$VOICEINK_TEST_PEER_CLONE" push origin main >/dev/null
        : > "$VOICEINK_TEST_PEER_PUSHED_PATH"
    fi
    if [[ "${VOICEINK_TEST_FAIL_AFTER_PEER_PUSH:-0}" == 1 ]]; then
        exit 1
    fi
    if [[ "${VOICEINK_TEST_REJECT_PUSH:-0}" == 1 ]]; then
        exit 1
    fi
    if [[ -n "${VOICEINK_TEST_AMBIGUOUS_PUSH_PATH:-}" ]]; then
        /usr/bin/git "$@"
        : > "$VOICEINK_TEST_AMBIGUOUS_PUSH_PATH"
        exit 1
    fi
    set +e
    /usr/bin/git "$@"
    git_status=$?
    set -e
    if [[ "$git_status" -eq 0 ]]; then
        if [[ -n "${VOICEINK_TEST_PUSH_COMPLETED_PATH:-}" ]]; then
            : > "$VOICEINK_TEST_PUSH_COMPLETED_PATH"
        fi
        exit 0
    fi
    exit "$git_status"
fi

if [[ " $* " == *" fetch origin main "* \
    && -n "${VOICEINK_TEST_FETCH_LOG:-}" ]]
then
    printf 'fetch\n' >> "$VOICEINK_TEST_FETCH_LOG"
fi

exec /usr/bin/git "$@"
EOF

chmod +x \
    "$fake_bin/codesign" \
    "$fake_bin/launch-voiceink" \
    "$fake_bin/relaunch-voiceink" \
    "$fake_bin/record-outcome" \
    "$fake_bin/fail-relaunch" \
    "$fake_bin/fail-snapshot" \
    "$fake_bin/restore-preferences" \
    "$fake_bin/restore-credentials" \
    "$fake_bin/create-credentials" \
    "$fake_bin/delete-credentials" \
    "$fake_bin/mutate-then-fail-replacement" \
    "$fake_bin/replace-bundle" \
    "$fake_bin/fail-replacement" \
    "$fake_bin/fail-pending-recovery-move" \
    "$fake_bin/git-with-late-update" \
    "$fake_bin/git-require-health-before-push"

credential_log="$fixture_root/credential-restore.log"
credential_create_log="$fixture_root/credential-create.log"
credential_delete_log="$fixture_root/credential-delete.log"
export VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH="$application_support"
export VOICEINK_UPDATE_PREFERENCES_PATH="$preferences"
export VOICEINK_UPDATE_PREFERENCES_RESTORER="$fake_bin/restore-preferences"
export VOICEINK_UPDATE_CREDENTIAL_RESTORER="$fake_bin/restore-credentials"
export VOICEINK_TEST_CREDENTIAL_LOG="$credential_log"
export VOICEINK_UPDATE_CREDENTIAL_SNAPSHOT_CREATOR="$fake_bin/create-credentials"
export VOICEINK_UPDATE_CREDENTIAL_SNAPSHOT_DELETER="$fake_bin/delete-credentials"
export VOICEINK_TEST_CREDENTIAL_CREATE_LOG="$credential_create_log"
export VOICEINK_TEST_CREDENTIAL_DELETE_LOG="$credential_delete_log"
# Cases that do not exercise the quit handshake use a parent that cannot answer it.
export VOICEINK_UPDATE_GRACEFUL_QUIT_TIMEOUT_SECONDS=0

intent_counter=0
prepare_recovery_intent() {
    intent_counter=$((intent_counter + 1))
    printf -v intent_suffix '%012x' "$intent_counter"
    export VOICEINK_UPDATE_CREDENTIAL_GENERATION="aaaaaaaa-aaaa-4aaa-8aaa-$intent_suffix"
    /bin/rm -rf "$recovery_root.pending"
    mkdir -m 700 "$recovery_root.pending"
    intent_previous_sha="$(/usr/bin/plutil -extract VoiceInkForkCommit raw "$installed_bundle/Contents/Info.plist")"
    /usr/bin/plutil -create xml1 "$recovery_root.pending/recovery.plist"
    /usr/bin/plutil -insert previousForkCommit -string "$intent_previous_sha" "$recovery_root.pending/recovery.plist"
    /usr/bin/plutil -insert candidateForkCommit -string "$new_sha" "$recovery_root.pending/recovery.plist"
    /usr/bin/plutil -insert credentialGeneration -string "$VOICEINK_UPDATE_CREDENTIAL_GENERATION" "$recovery_root.pending/recovery.plist"
    /usr/bin/plutil -insert installInProgress -bool true "$recovery_root.pending/recovery.plist"
    /usr/bin/plutil -insert restoreInProgress -bool false "$recovery_root.pending/recovery.plist"
    /usr/bin/plutil -insert permissionState -dictionary "$recovery_root.pending/recovery.plist"
    /usr/bin/plutil -insert permissionState.microphoneAuthorized -bool true "$recovery_root.pending/recovery.plist"
    /usr/bin/plutil -insert permissionState.accessibilityAuthorized -bool true "$recovery_root.pending/recovery.plist"
    /usr/bin/plutil -insert permissionState.screenCaptureAuthorized -bool true "$recovery_root.pending/recovery.plist"
    chmod 600 "$recovery_root.pending/recovery.plist"
}

staged_bundle="$fixture_root/staging/candidates/$new_sha/VoiceInk.app"
/usr/bin/plutil -replace forkCommit -string "$new_sha" "$manifest_path"
/usr/bin/plutil -replace upstreamCommit -string "$upstream_sha" "$manifest_path"
/usr/bin/plutil -replace bundlePath -string "$staged_bundle" "$manifest_path"

prepare_recovery_intent
peer_clone="$fixture_root/peer"
peer_pushed_path="$fixture_root/peer-pushed"
peer_fetch_log="$fixture_root/peer-fetch.log"
git clone "$fork_bare" "$peer_clone" >/dev/null
git -C "$peer_clone" config user.name "VoiceInk Peer Test"
git -C "$peer_clone" config user.email "peer-test@example.com"
printf 'peer update\n' > "$peer_clone/peer-update"
git -C "$peer_clone" add peer-update
git -C "$peer_clone" commit -m "test: publish peer update" >/dev/null
peer_sha="$(git -C "$peer_clone" rev-parse HEAD)"
set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH="$application_support" \
    VOICEINK_UPDATE_PREFERENCES_PATH="$preferences" \
    VOICEINK_UPDATE_AVAILABLE_DISK_KIB=0 \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/disk-space-output.log" 2>&1
disk_space_status=$?
set -e

[[ "$disk_space_status" -ne 0 ]]
kill -0 "$parent_pid"
[[ "$(< "$installed_bundle/Contents/version")" == "installed-before-update" ]]
[[ ! -e "$recovery_root" ]]
grep -Fq "disk space" "$fixture_root/disk-space-output.log"

: > "$launch_log"
prepare_recovery_intent
set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH="$application_support" \
    VOICEINK_UPDATE_PREFERENCES_PATH="$preferences" \
    VOICEINK_UPDATE_STATE_SNAPSHOTTER="$fake_bin/fail-snapshot" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/snapshot-output.log" 2>&1
snapshot_status=$?
set -e

[[ "$snapshot_status" -ne 0 ]]
if kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: approved parent survived snapshot failure\n' >&2
    exit 1
fi
parent_pid=""
[[ "$(< "$installed_bundle/Contents/version")" == "installed-before-update" ]]
[[ ! -e "$recovery_root" ]]
grep -Fqx "rollback:$installed_bundle" "$launch_log"
grep -Fq "snapshot" "$fixture_root/snapshot-output.log"

sleep 30 &
parent_pid=$!
prepare_recovery_intent
set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_STATE_SNAPSHOTTER="$fake_bin/fail-snapshot" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/fail-relaunch" \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/relaunch-failure-output.log" 2>&1
relaunch_failure_status=$?
set -e

[[ "$relaunch_failure_status" -eq 2 ]]
if kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: approved parent survived relaunch-failure setup\n' >&2
    exit 1
fi
parent_pid=""
grep -Fq "could not relaunch the previous version" "$fixture_root/relaunch-failure-output.log"

# Graceful quit: the installer asks the app to quit through its normal
# termination path and only signals it after the graceful request times out.
cat > "$fake_bin/quit-aware-parent" <<'EOF'
#!/usr/bin/env bash
request_path="$1"
response_path="$2"
marker_path="$3"
mode="$4"
trap 'printf "signal\n" >> "$marker_path"; exit 143' TERM
for ((attempt = 0; attempt < 300; attempt++)); do
    if [[ -f "$request_path" ]]; then
        printf 'requested\n' >> "$marker_path"
        if [[ "$mode" != ignore ]]; then
            printf '%s\n' "$mode" > "$response_path.tmp"
            mv "$response_path.tmp" "$response_path"
        fi
        if [[ "$mode" == quit ]]; then
            printf 'graceful\n' >> "$marker_path"
            exit 0
        fi
        break
    fi
    sleep 0.1
done
for ((attempt = 0; attempt < 300; attempt++)); do
    sleep 0.1
done
EOF
chmod +x "$fake_bin/quit-aware-parent"

quit_request_path="$fixture_root/quit/request"
quit_response_path="$fixture_root/quit/response"
quit_marker="$fixture_root/quit/marker"
mkdir -p "$fixture_root/quit"

run_quit_installation() {
    local graceful_timeout="$1"
    local output_path="$2"
    PATH="$fake_bin:$PATH" \
        VOICEINK_REPOSITORY_PATH="$canonical_clone" \
        VOICEINK_UPDATE_STATE_SNAPSHOTTER="$fake_bin/fail-snapshot" \
        VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
        VOICEINK_UPDATE_GRACEFUL_QUIT_TIMEOUT_SECONDS="$graceful_timeout" \
        VOICEINK_UPDATE_QUIT_REQUEST_PATH="$quit_request_path" \
        VOICEINK_UPDATE_QUIT_RESPONSE_PATH="$quit_response_path" \
        VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
        /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
        "$new_sha" \
        "$manifest_path" \
        "$installed_bundle" \
        "$backup_bundle" \
        "$parent_pid" \
        > "$output_path" 2>&1
}

: > "$quit_marker"
"$fake_bin/quit-aware-parent" "$quit_request_path" "$quit_response_path" "$quit_marker" quit &
parent_pid=$!
prepare_recovery_intent
set +e
run_quit_installation 10 "$fixture_root/graceful-quit-output.log"
graceful_quit_status=$?
set -e

[[ "$graceful_quit_status" -ne 0 ]]
if kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: parent survived the graceful quit request\n' >&2
    exit 1
fi
parent_pid=""
grep -Fqx "requested" "$quit_marker"
grep -Fqx "graceful" "$quit_marker"
if grep -Fqx "signal" "$quit_marker"; then
    printf 'install-local-update-test: installer signalled a parent that quit gracefully\n' >&2
    exit 1
fi
if grep -Fq "SIGTERM" "$fixture_root/graceful-quit-output.log"; then
    printf 'install-local-update-test: installer reported a SIGTERM fallback after a graceful quit\n' >&2
    exit 1
fi
[[ ! -e "$quit_request_path" ]]
grep -Fq "snapshot" "$fixture_root/graceful-quit-output.log"

: > "$quit_marker"
/bin/rm -f "$quit_response_path"
"$fake_bin/quit-aware-parent" "$quit_request_path" "$quit_response_path" "$quit_marker" ignore &
parent_pid=$!
prepare_recovery_intent
set +e
run_quit_installation 1 "$fixture_root/quit-fallback-output.log"
quit_fallback_status=$?
set -e

[[ "$quit_fallback_status" -ne 0 ]]
if kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: parent survived the SIGTERM fallback\n' >&2
    exit 1
fi
parent_pid=""
grep -Fqx "requested" "$quit_marker"
grep -Fqx "signal" "$quit_marker"
grep -Fq "sending SIGTERM" "$fixture_root/quit-fallback-output.log"
[[ ! -e "$quit_request_path" ]]

: > "$quit_marker"
: > "$launch_log"
: > "$credential_delete_log"
/bin/rm -f "$quit_response_path"
"$fake_bin/quit-aware-parent" "$quit_request_path" "$quit_response_path" "$quit_marker" busy &
parent_pid=$!
prepare_recovery_intent
set +e
run_quit_installation 10 "$fixture_root/quit-busy-output.log"
quit_busy_status=$?
set -e

[[ "$quit_busy_status" -eq 76 ]]
if ! kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: installer terminated a busy parent\n' >&2
    exit 1
fi
grep -Fqx "requested" "$quit_marker"
if grep -Fqx "signal" "$quit_marker"; then
    printf 'install-local-update-test: installer signalled a busy parent\n' >&2
    exit 1
fi
[[ "$(< "$installed_bundle/Contents/version")" == "installed-before-update" ]]
[[ ! -e "$recovery_root.pending" ]]
[[ ! -e "$recovery_root" ]]
[[ ! -s "$launch_log" ]]
[[ ! -e "$quit_request_path" ]]
grep -Fqx "$VOICEINK_UPDATE_CREDENTIAL_GENERATION" "$credential_delete_log"
grep -Fq "Update cancelled" "$fixture_root/quit-busy-output.log"
kill "$parent_pid" >/dev/null 2>&1 || true
wait "$parent_pid" 2>/dev/null || true
parent_pid=""

sleep 30 &
parent_pid=$!
: > "$launch_log"

fork_base_sha="$new_sha"
printf 'verified-before-publish\n' > "$seed_clone/verified-candidate"
git -C "$seed_clone" add verified-candidate
git -C "$seed_clone" commit -m "chore(updater): merge upstream main" >/dev/null
new_sha="$(git -C "$seed_clone" rev-parse HEAD)"
git -C "$canonical_clone" fetch "$seed_clone" "$new_sha" >/dev/null
candidate_ref="refs/voiceink-updater/candidates/$new_sha-$(date +%s)-$$"
staged_bundle="$fixture_root/staging/candidates/$new_sha/VoiceInk.app"

stage_publishable_candidate() {
    local candidate_version="$1"
    git -C "$canonical_clone" update-ref "$candidate_ref" "$new_sha"
    mkdir -p "$staged_bundle/Contents"
    printf '%s\n' "$candidate_version" > "$staged_bundle/Contents/version"
    /usr/bin/plutil -create xml1 "$staged_bundle/Contents/Info.plist"
    /usr/bin/plutil -insert VoiceInkForkCommit -string "$new_sha" "$staged_bundle/Contents/Info.plist"
    /usr/bin/plutil -insert VoiceInkUpstreamCommit -string "$upstream_sha" "$staged_bundle/Contents/Info.plist"
    /usr/bin/plutil -insert VoiceInkUpdaterKind -string fork "$staged_bundle/Contents/Info.plist"
    /usr/bin/plutil -create xml1 "$manifest_path"
    /usr/bin/plutil -insert forkCommit -string "$new_sha" "$manifest_path"
    /usr/bin/plutil -insert forkBaseCommit -string "$fork_base_sha" "$manifest_path"
    /usr/bin/plutil -insert upstreamCommit -string "$upstream_sha" "$manifest_path"
    /usr/bin/plutil -insert candidateRef -string "$candidate_ref" "$manifest_path"
    /usr/bin/plutil -insert bundlePath -string "$staged_bundle" "$manifest_path"
}

stage_publishable_candidate newer-candidate
publish_log="$fixture_root/publish.log"

git -C "$canonical_clone" config user.name "VoiceInk Local Divergence Test"
git -C "$canonical_clone" config user.email "local-divergence@example.com"
printf 'local-only\n' > "$canonical_clone/local-only"
git -C "$canonical_clone" add local-only
git -C "$canonical_clone" commit -m "test: diverge local main" >/dev/null
divergent_local_sha="$(git -C "$canonical_clone" rev-parse HEAD)"
prepare_recovery_intent
set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_GIT_COMMAND="$fake_bin/git-require-health-before-push" \
    VOICEINK_UPDATE_LAUNCHER="$fake_bin/launch-voiceink" \
    VOICEINK_UPDATE_ATOMIC_REPLACER="$fake_bin/replace-bundle" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_UPDATE_HEALTH_PATH="$health_path" \
    VOICEINK_UPDATE_HEALTH_TIMEOUT_SECONDS=2 \
    VOICEINK_UPDATE_STABILITY_SECONDS=1 \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
    VOICEINK_TEST_REQUIRED_HEALTH_PATH="$health_path" \
    VOICEINK_TEST_REQUIRED_PUBLISH_SHA="$new_sha" \
    VOICEINK_TEST_PUBLISH_LOG="$publish_log" \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/divergent-local-output.log" 2>&1
divergent_local_status=$?
set -e

[[ "$divergent_local_status" -eq 75 ]]
kill -0 "$parent_pid"
[[ "$(git --git-dir="$fork_bare" rev-parse refs/heads/main)" == "$fork_base_sha" ]]
[[ "$(git -C "$canonical_clone" rev-parse refs/heads/main)" == "$divergent_local_sha" ]]
grep -Fq "Local main cannot fast-forward" "$fixture_root/divergent-local-output.log"
git -C "$canonical_clone" switch --detach "$old_sha" >/dev/null
git -C "$canonical_clone" branch -f main "$old_sha"
git -C "$canonical_clone" switch main >/dev/null

git -C "$canonical_clone" switch -c local-work >/dev/null
printf 'keep local work\n' > "$canonical_clone/uncommitted-local-work"
dirty_before_status="$(git -C "$canonical_clone" status --porcelain)"
dirty_before_head="$(git -C "$canonical_clone" rev-parse HEAD)"
set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_AVAILABLE_DISK_KIB=0 \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/dirty-install-output.log" 2>&1
dirty_install_status=$?
set -e

[[ "$dirty_install_status" -eq 75 ]]
kill -0 "$parent_pid"
[[ "$(git -C "$canonical_clone" rev-parse HEAD)" == "$dirty_before_head" ]]
[[ "$(git -C "$canonical_clone" status --porcelain)" == "$dirty_before_status" ]]
[[ "$(< "$canonical_clone/uncommitted-local-work")" == "keep local work" ]]
[[ "$(< "$installed_bundle/Contents/version")" == "installed-before-update" ]]
grep -Fq "changed during preparation" "$fixture_root/dirty-install-output.log"
rm "$canonical_clone/uncommitted-local-work"
git -C "$canonical_clone" switch main >/dev/null
git -C "$canonical_clone" branch -D local-work >/dev/null

unsafe_history_repo="$fixture_root/unsafe-history"
git init --initial-branch=main "$unsafe_history_repo" >/dev/null
git -C "$unsafe_history_repo" config user.name "VoiceInk Unsafe History Test"
git -C "$unsafe_history_repo" config user.email "unsafe-history@example.com"
printf 'unrelated history\n' > "$unsafe_history_repo/version"
git -C "$unsafe_history_repo" add version
git -C "$unsafe_history_repo" commit -m "test: replace fork history" >/dev/null
unsafe_history_sha="$(git -C "$unsafe_history_repo" rev-parse HEAD)"
git --git-dir="$fork_bare" fetch "$unsafe_history_repo" main >/dev/null
git --git-dir="$fork_bare" update-ref refs/heads/main "$unsafe_history_sha" "$fork_base_sha"

set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_AVAILABLE_DISK_KIB=0 \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/unsafe-history-output.log" 2>&1
unsafe_history_status=$?
set -e

[[ "$unsafe_history_status" -eq 75 ]]
kill -0 "$parent_pid"
[[ "$(< "$installed_bundle/Contents/version")" == "installed-before-update" ]]
[[ "$(git -C "$canonical_clone" rev-parse refs/heads/main)" == "$old_sha" ]]
[[ ! -e "$manifest_path" ]]
[[ ! -e "$staged_bundle" ]]
if git -C "$canonical_clone" rev-parse "$candidate_ref" >/dev/null 2>&1; then
    printf 'install-local-update-test: unsafe-history candidate reference survived\n' >&2
    exit 1
fi
grep -Fq "does not descend from the installed VoiceInk revision" "$fixture_root/unsafe-history-output.log"

git --git-dir="$fork_bare" update-ref refs/heads/main "$fork_base_sha" "$unsafe_history_sha"
stage_publishable_candidate newer-candidate

prepare_recovery_intent
set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_GIT_COMMAND="$fake_bin/git-require-health-before-push" \
    VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH="$application_support" \
    VOICEINK_UPDATE_PREFERENCES_PATH="$preferences" \
    VOICEINK_UPDATE_LAUNCHER="$fake_bin/launch-voiceink" \
    VOICEINK_UPDATE_ATOMIC_REPLACER="$fake_bin/replace-bundle" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_UPDATE_HEALTH_PATH="$health_path" \
    VOICEINK_UPDATE_HEALTH_TIMEOUT_SECONDS=2 \
    VOICEINK_UPDATE_STABILITY_SECONDS=1 \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
    VOICEINK_TEST_REQUIRED_HEALTH_PATH="$health_path" \
    VOICEINK_TEST_REQUIRED_PUBLISH_SHA="$new_sha" \
    VOICEINK_TEST_EXPECTED_LOCAL_MAIN_BEFORE_PUSH="$old_sha" \
    VOICEINK_TEST_PUBLISH_LOG="$publish_log" \
    VOICEINK_TEST_PEER_CLONE="$peer_clone" \
    VOICEINK_TEST_PEER_PUSHED_PATH="$peer_pushed_path" \
    VOICEINK_TEST_FETCH_LOG="$peer_fetch_log" \
    VOICEINK_UPDATE_OUTCOME_RECORDER="$fake_bin/record-outcome" \
    VOICEINK_TEST_OUTCOME_REPORT="$fixture_root/rejected-push-outcome.plist" \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/rejected-push-output.log" 2>&1
rejected_push_status=$?
set -e

[[ "$rejected_push_status" -eq 75 ]]
if kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: approved parent survived rejected-push setup\n' >&2
    exit 1
fi
parent_pid=""
[[ "$(< "$installed_bundle/Contents/version")" == "installed-before-update" ]]
[[ "$(git --git-dir="$fork_bare" rev-parse refs/heads/main)" == "$peer_sha" ]]
[[ "$(git -C "$canonical_clone" rev-parse refs/heads/main)" == "$old_sha" ]]
[[ ! -e "$manifest_path" ]]
[[ ! -e "$staged_bundle" ]]
if git -C "$canonical_clone" rev-parse "$candidate_ref" >/dev/null 2>&1; then
    printf 'install-local-update-test: stale peer candidate reference survived\n' >&2
    exit 1
fi
[[ "$(grep -c '^fetch$' "$peer_fetch_log")" -eq 4 ]]
grep -Fq "another Mac changed the fork; prepare and approve a new candidate" "$fixture_root/rejected-push-output.log"
# A discarded candidate is a rolled-back installation, not a pending publication.
[[ "$(/usr/bin/plutil -extract failureStage raw "$fixture_root/rejected-push-outcome.plist")" == "installation" ]]
[[ "$(/usr/bin/plutil -extract rollbackOutcome raw "$fixture_root/rejected-push-outcome.plist")" == "succeeded" ]]
if grep -Fq "publication to the fork is pending" "$fixture_root/rejected-push-outcome.plist"; then
    printf 'install-local-update-test: discarded candidate was reported as pending publication\n' >&2
    exit 1
fi

git --git-dir="$fork_bare" update-ref refs/heads/main "$fork_base_sha" "$peer_sha"
original_new_sha="$new_sha"
original_upstream_sha="$upstream_sha"
original_candidate_ref="$candidate_ref"
original_staged_bundle="$staged_bundle"

conflict_candidate_worktree="$fixture_root/conflict-candidate"
git -C "$seed_clone" worktree add --detach "$conflict_candidate_worktree" "$fork_base_sha" >/dev/null
git -C "$conflict_candidate_worktree" config user.name "VoiceInk Updater Test"
git -C "$conflict_candidate_worktree" config user.email "updater-test@example.com"
printf 'upstream version\n' > "$conflict_candidate_worktree/convergence"
git -C "$conflict_candidate_worktree" add convergence
git -C "$conflict_candidate_worktree" commit -m "test: prepare conflicting upstream" >/dev/null
conflict_candidate_sha="$(git -C "$conflict_candidate_worktree" rev-parse HEAD)"
git -C "$seed_clone" worktree remove "$conflict_candidate_worktree"
git -C "$canonical_clone" fetch "$seed_clone" "$conflict_candidate_sha" >/dev/null

conflict_peer_clone="$fixture_root/conflict-peer"
conflict_peer_pushed_path="$fixture_root/conflict-peer-pushed"
conflict_fetch_log="$fixture_root/conflict-fetch.log"
git clone "$fork_bare" "$conflict_peer_clone" >/dev/null
git -C "$conflict_peer_clone" config user.name "VoiceInk Peer Test"
git -C "$conflict_peer_clone" config user.email "peer-test@example.com"
printf 'peer version\n' > "$conflict_peer_clone/convergence"
git -C "$conflict_peer_clone" add convergence
git -C "$conflict_peer_clone" commit -m "test: publish conflicting peer update" >/dev/null
conflict_peer_sha="$(git -C "$conflict_peer_clone" rev-parse HEAD)"

new_sha="$conflict_candidate_sha"
upstream_sha="$conflict_candidate_sha"
candidate_ref="refs/voiceink-updater/candidates/$new_sha-$(date +%s)-$$"
staged_bundle="$fixture_root/staging/candidates/$new_sha/VoiceInk.app"
stage_publishable_candidate conflicting-candidate

sleep 30 &
parent_pid=$!
: > "$launch_log"
: > "$publish_log"
prepare_recovery_intent
set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_GIT_COMMAND="$fake_bin/git-require-health-before-push" \
    VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH="$application_support" \
    VOICEINK_UPDATE_PREFERENCES_PATH="$preferences" \
    VOICEINK_UPDATE_LAUNCHER="$fake_bin/launch-voiceink" \
    VOICEINK_UPDATE_ATOMIC_REPLACER="$fake_bin/replace-bundle" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_UPDATE_HEALTH_PATH="$health_path" \
    VOICEINK_UPDATE_HEALTH_TIMEOUT_SECONDS=2 \
    VOICEINK_UPDATE_STABILITY_SECONDS=1 \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
    VOICEINK_TEST_REQUIRED_HEALTH_PATH="$health_path" \
    VOICEINK_TEST_REQUIRED_PUBLISH_SHA="$new_sha" \
    VOICEINK_TEST_EXPECTED_LOCAL_MAIN_BEFORE_PUSH="$old_sha" \
    VOICEINK_TEST_PUBLISH_LOG="$publish_log" \
    VOICEINK_TEST_PEER_CLONE="$conflict_peer_clone" \
    VOICEINK_TEST_PEER_PUSHED_PATH="$conflict_peer_pushed_path" \
    VOICEINK_TEST_FETCH_LOG="$conflict_fetch_log" \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/conflict-recompute-output.log" 2>&1
conflict_recompute_status=$?
set -e

[[ "$conflict_recompute_status" -eq 1 ]]
if kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: approved parent survived conflict recomputation\n' >&2
    exit 1
fi
parent_pid=""
[[ "$(< "$installed_bundle/Contents/version")" == "installed-before-update" ]]
[[ "$(git --git-dir="$fork_bare" rev-parse refs/heads/main)" == "$conflict_peer_sha" ]]
[[ "$(git -C "$canonical_clone" rev-parse refs/heads/main)" == "$old_sha" ]]
[[ ! -e "$manifest_path" ]]
[[ ! -e "$staged_bundle" ]]
if git -C "$canonical_clone" rev-parse "$candidate_ref" >/dev/null 2>&1; then
    printf 'install-local-update-test: conflicting candidate reference survived\n' >&2
    exit 1
fi
[[ "$(grep -c '^fetch$' "$conflict_fetch_log")" -eq 4 ]]
[[ "$(grep -Fc 'the recomputed update conflicts with it' "$fixture_root/conflict-recompute-output.log")" -eq 1 ]]

git --git-dir="$fork_bare" update-ref refs/heads/main "$fork_base_sha" "$conflict_peer_sha"
new_sha="$original_new_sha"
upstream_sha="$original_upstream_sha"
candidate_ref="$original_candidate_ref"
staged_bundle="$original_staged_bundle"
stage_publishable_candidate newer-candidate

run_successful_peer_convergence() {
    local peer_clone="$1"
    local peer_sha="$2"
    local scenario="$3"
    local fetch_log="$fixture_root/$scenario-fetch.log"
    local peer_pushed_path="$fixture_root/$scenario-peer-pushed"
    local output_log="$fixture_root/$scenario-output.log"
    local converged_launched_pid

    sleep 30 &
    parent_pid=$!
    : > "$launch_log"
    : > "$publish_log"
    prepare_recovery_intent
    PATH="$fake_bin:$PATH" \
        VOICEINK_REPOSITORY_PATH="$canonical_clone" \
        VOICEINK_UPDATE_GIT_COMMAND="$fake_bin/git-require-health-before-push" \
        VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH="$application_support" \
        VOICEINK_UPDATE_PREFERENCES_PATH="$preferences" \
        VOICEINK_UPDATE_LAUNCHER="$fake_bin/launch-voiceink" \
        VOICEINK_UPDATE_ATOMIC_REPLACER="$fake_bin/replace-bundle" \
        VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
        VOICEINK_UPDATE_HEALTH_PATH="$health_path" \
        VOICEINK_UPDATE_HEALTH_TIMEOUT_SECONDS=2 \
        VOICEINK_UPDATE_STABILITY_SECONDS=1 \
        VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
        VOICEINK_TEST_REQUIRED_HEALTH_PATH="$health_path" \
        VOICEINK_TEST_REQUIRED_PUBLISH_SHA="$new_sha" \
        VOICEINK_TEST_EXPECTED_LOCAL_MAIN_BEFORE_PUSH="$old_sha" \
        VOICEINK_TEST_PUBLISH_LOG="$publish_log" \
        VOICEINK_TEST_PEER_CLONE="$peer_clone" \
        VOICEINK_TEST_PEER_PUSHED_PATH="$peer_pushed_path" \
        VOICEINK_TEST_FAIL_AFTER_PEER_PUSH=1 \
        VOICEINK_TEST_FETCH_LOG="$fetch_log" \
        /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
        "$new_sha" \
        "$manifest_path" \
        "$installed_bundle" \
        "$backup_bundle" \
        "$parent_pid" \
        > "$output_log" 2>&1

    if kill -0 "$parent_pid" >/dev/null 2>&1; then
        printf 'install-local-update-test: approved parent survived %s convergence\n' "$scenario" >&2
        exit 1
    fi
    parent_pid=""
    [[ "$(< "$installed_bundle/Contents/version")" == "newer-candidate" ]]
    [[ "$(git --git-dir="$fork_bare" rev-parse refs/heads/main)" == "$peer_sha" ]]
    [[ "$(git -C "$canonical_clone" rev-parse refs/heads/main)" == "$peer_sha" ]]
    [[ ! -e "$manifest_path" ]]
    [[ ! -e "$staged_bundle" ]]
    if git -C "$canonical_clone" rev-parse "$candidate_ref" >/dev/null 2>&1; then
        printf 'install-local-update-test: %s candidate reference survived\n' "$scenario" >&2
        exit 1
    fi
    if [[ "$(grep -c '^fetch$' "$fetch_log")" -ne 4 ]]; then
        printf 'install-local-update-test: %s convergence did not use one reconciliation fetch\n' "$scenario" >&2
        exit 1
    fi

    converged_launched_pid="$(/usr/bin/plutil -extract processIdentifier raw "$health_path")"
    kill "$converged_launched_pid"
    /bin/rm -rf "$installed_bundle"
    /usr/bin/ditto "$backup_bundle" "$installed_bundle"
    git --git-dir="$fork_bare" update-ref refs/heads/main "$fork_base_sha" "$peer_sha"
    git -C "$canonical_clone" switch --detach "$old_sha" >/dev/null
    git -C "$canonical_clone" branch -f main "$old_sha"
    git -C "$canonical_clone" switch main >/dev/null
    stage_publishable_candidate newer-candidate
}

exact_peer_clone="$fixture_root/exact-peer"
git clone "$fork_bare" "$exact_peer_clone" >/dev/null
git -C "$exact_peer_clone" fetch "$canonical_clone" "$new_sha" >/dev/null
git -C "$exact_peer_clone" merge --ff-only "$new_sha" >/dev/null
run_successful_peer_convergence "$exact_peer_clone" "$new_sha" exact-peer

descendant_peer_clone="$fixture_root/descendant-peer"
git clone "$fork_bare" "$descendant_peer_clone" >/dev/null
git -C "$descendant_peer_clone" config user.name "VoiceInk Peer Test"
git -C "$descendant_peer_clone" config user.email "peer-test@example.com"
git -C "$descendant_peer_clone" fetch "$canonical_clone" "$new_sha" >/dev/null
git -C "$descendant_peer_clone" merge --ff-only "$new_sha" >/dev/null
printf 'peer descendant\n' > "$descendant_peer_clone/peer-descendant"
git -C "$descendant_peer_clone" add peer-descendant
git -C "$descendant_peer_clone" commit -m "test: publish after approved candidate" >/dev/null
descendant_peer_sha="$(git -C "$descendant_peer_clone" rev-parse HEAD)"
run_successful_peer_convergence "$descendant_peer_clone" "$descendant_peer_sha" descendant-peer

sleep 30 &
parent_pid=$!
: > "$launch_log"
: > "$publish_log"
prepare_recovery_intent
ambiguous_push_path="$fixture_root/ambiguous-push"
set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_GIT_COMMAND="$fake_bin/git-require-health-before-push" \
    VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH="$application_support" \
    VOICEINK_UPDATE_PREFERENCES_PATH="$preferences" \
    VOICEINK_UPDATE_LAUNCHER="$fake_bin/launch-voiceink" \
    VOICEINK_UPDATE_ATOMIC_REPLACER="$fake_bin/replace-bundle" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_UPDATE_HEALTH_PATH="$health_path" \
    VOICEINK_UPDATE_HEALTH_TIMEOUT_SECONDS=2 \
    VOICEINK_UPDATE_STABILITY_SECONDS=1 \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
    VOICEINK_TEST_REQUIRED_HEALTH_PATH="$health_path" \
    VOICEINK_TEST_REQUIRED_PUBLISH_SHA="$new_sha" \
    VOICEINK_TEST_EXPECTED_LOCAL_MAIN_BEFORE_PUSH="$old_sha" \
    VOICEINK_TEST_PUBLISH_LOG="$publish_log" \
    VOICEINK_TEST_AMBIGUOUS_PUSH_PATH="$ambiguous_push_path" \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/ambiguous-push-output.log" 2>&1
ambiguous_push_status=$?
set -e

[[ "$ambiguous_push_status" -ne 0 ]]
if kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: approved parent survived ambiguous-push setup\n' >&2
    exit 1
fi
parent_pid=""
[[ "$(< "$installed_bundle/Contents/version")" == "newer-candidate" ]]
[[ "$(git --git-dir="$fork_bare" rev-parse refs/heads/main)" == "$new_sha" ]]
[[ "$(git -C "$canonical_clone" rev-parse refs/heads/main)" == "$old_sha" ]]
[[ -f "$manifest_path" ]]
[[ -d "$staged_bundle" ]]
[[ "$(git -C "$canonical_clone" rev-parse "$candidate_ref")" == "$new_sha" ]]
grep -Fq "could not determine whether publication succeeded" "$fixture_root/ambiguous-push-output.log"
if grep -Fq "rollback:$installed_bundle" "$launch_log"; then
    printf 'install-local-update-test: ambiguous publication rolled back the healthy candidate\n' >&2
    exit 1
fi

ambiguous_launched_pid="$(/usr/bin/plutil -extract processIdentifier raw "$health_path")"
kill "$ambiguous_launched_pid"
/bin/rm -rf "$installed_bundle"
/usr/bin/ditto "$backup_bundle" "$installed_bundle"
git --git-dir="$fork_bare" update-ref refs/heads/main "$fork_base_sha" "$new_sha"

# Publication failures after the health window must keep the healthy app
# running, retain the staged candidate, and let the next preparation run
# publish the installed candidate without rebuilding it.
upstream_bare="$fixture_root/upstream.git"
git init --bare --initial-branch=main "$upstream_bare" >/dev/null
git -C "$canonical_clone" push "$upstream_bare" "$new_sha:refs/heads/main" >/dev/null 2>&1
git -C "$canonical_clone" remote add upstream "$upstream_bare"

cat > "$fake_bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
printf 'install-local-update-test: preparation rebuilt the installed candidate\n' >&2
exit 1
EOF
chmod +x "$fake_bin/xcodebuild"

pending_original_staged_bundle="$staged_bundle"
staged_bundle="$fixture_root/staging/candidates/$new_sha-1-1/VoiceInk.app"

expect_pending_retry_failure() {
    local retry_scenario="$1"
    local retry_result="$fixture_root/$retry_scenario-preparation.plist"

    if PATH="$fake_bin:$PATH" \
        VOICEINK_REPOSITORY_PATH="$canonical_clone" \
        VOICEINK_UPDATE_MANIFEST_PATH="$manifest_path" \
        VOICEINK_UPDATE_RESULT_PATH="$retry_result" \
        VOICEINK_INSTALLED_FORK_COMMIT="$new_sha" \
        /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
        > "$fixture_root/$retry_scenario-output.log" 2>&1
    then
        printf 'install-local-update-test: %s retry succeeded unexpectedly\n' "$retry_scenario" >&2
        exit 1
    fi
    [[ "$(/usr/bin/plutil -extract outcome raw "$retry_result")" == "failure" ]]
    [[ "$(/usr/bin/plutil -extract stage raw "$retry_result")" == "publication" ]]
    [[ "$(/usr/bin/plutil -extract kind raw "$retry_result")" == "transient" ]]
    grep -Fq "publication to the fork is pending" "$retry_result"
    [[ "$(/usr/bin/plutil -extract forkCommit raw "$manifest_path")" == "$new_sha" ]]
    [[ "$(git -C "$canonical_clone" rev-parse "$candidate_ref")" == "$new_sha" ]]
    [[ "$(git --git-dir="$fork_bare" rev-parse refs/heads/main)" == "$fork_base_sha" ]]
}

run_pending_publication() {
    local scenario="$1"
    shift
    local output_log="$fixture_root/$scenario-output.log"
    local pending_outcome="$fixture_root/$scenario-outcome.plist"
    local preparation_result="$fixture_root/$scenario-preparation.plist"
    local pending_status
    local pending_launched_pid

    stage_publishable_candidate newer-candidate
    sleep 30 &
    parent_pid=$!
    : > "$launch_log"
    : > "$publish_log"
    /bin/rm -f "$health_path"
    prepare_recovery_intent
    set +e
    env "$@" \
        PATH="$fake_bin:$PATH" \
        VOICEINK_REPOSITORY_PATH="$canonical_clone" \
        VOICEINK_UPDATE_GIT_COMMAND="$fake_bin/git-require-health-before-push" \
        VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH="$application_support" \
        VOICEINK_UPDATE_PREFERENCES_PATH="$preferences" \
        VOICEINK_UPDATE_LAUNCHER="$fake_bin/launch-voiceink" \
        VOICEINK_UPDATE_ATOMIC_REPLACER="$fake_bin/replace-bundle" \
        VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
        VOICEINK_UPDATE_OUTCOME_RECORDER="$fake_bin/record-outcome" \
        VOICEINK_UPDATE_HEALTH_PATH="$health_path" \
        VOICEINK_UPDATE_HEALTH_TIMEOUT_SECONDS=2 \
        VOICEINK_UPDATE_STABILITY_SECONDS=1 \
        VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
        VOICEINK_TEST_REQUIRED_HEALTH_PATH="$health_path" \
        VOICEINK_TEST_REQUIRED_PUBLISH_SHA="$new_sha" \
        VOICEINK_TEST_PUBLISH_LOG="$publish_log" \
        VOICEINK_TEST_OUTCOME_REPORT="$pending_outcome" \
        /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
        "$new_sha" \
        "$manifest_path" \
        "$installed_bundle" \
        "$backup_bundle" \
        "$parent_pid" \
        > "$output_log" 2>&1
    pending_status=$?
    set -e

    if [[ "$pending_status" -eq 0 ]]; then
        printf 'install-local-update-test: %s publication failure reported success\n' "$scenario" >&2
        exit 1
    fi
    if kill -0 "$parent_pid" >/dev/null 2>&1; then
        printf 'install-local-update-test: approved parent survived %s installation\n' "$scenario" >&2
        exit 1
    fi
    parent_pid=""
    pending_launched_pid="$(/usr/bin/plutil -extract processIdentifier raw "$health_path")"
    if ! kill -0 "$pending_launched_pid" >/dev/null 2>&1; then
        printf 'install-local-update-test: %s publication failure stopped the healthy app\n' "$scenario" >&2
        exit 1
    fi
    if grep -Fq "rollback:" "$launch_log"; then
        printf 'install-local-update-test: %s publication failure rolled back the healthy app\n' "$scenario" >&2
        exit 1
    fi
    [[ "$(< "$installed_bundle/Contents/version")" == "newer-candidate" ]]
    [[ "$(/usr/bin/plutil -extract installInProgress raw "$recovery_root/recovery.plist")" == "false" ]]
    if /usr/bin/plutil -extract suppressedForkCommit raw "$recovery_root/recovery.plist" >/dev/null 2>&1; then
        printf 'install-local-update-test: %s publication failure suppressed the candidate\n' "$scenario" >&2
        exit 1
    fi
    [[ ! -s "$publish_log" ]]
    [[ "$(git --git-dir="$fork_bare" rev-parse refs/heads/main)" == "$fork_base_sha" ]]
    [[ "$(git -C "$canonical_clone" rev-parse refs/heads/main)" == "$old_sha" ]]
    [[ "$(/usr/bin/plutil -extract forkCommit raw "$manifest_path")" == "$new_sha" ]]
    [[ "$(/usr/bin/plutil -extract candidateRef raw "$manifest_path")" == "$candidate_ref" ]]
    [[ -d "$staged_bundle" ]]
    [[ "$(git -C "$canonical_clone" rev-parse "$candidate_ref")" == "$new_sha" ]]
    [[ "$(/usr/bin/plutil -extract outcome raw "$pending_outcome")" == "failed" ]]
    [[ "$(/usr/bin/plutil -extract failureStage raw "$pending_outcome")" == "publication" ]]
    grep -Fq "publication to the fork is pending" "$pending_outcome"
    if /usr/bin/plutil -extract rollbackOutcome raw "$pending_outcome" >/dev/null 2>&1; then
        printf 'install-local-update-test: %s publication failure recorded a rollback\n' "$scenario" >&2
        exit 1
    fi
    grep -Fq "publication is pending" "$output_log"

    # A retry that still cannot publish keeps reporting the pending publication.
    if [[ -n "${pending_cleanup_path:-}" ]]; then
        expect_pending_retry_failure "$scenario-still-dirty"
        /bin/rm -f "$pending_cleanup_path"
    else
        git -C "$canonical_clone" remote set-url origin "$fixture_root/unreachable.git"
        expect_pending_retry_failure "$scenario-still-offline"
        git -C "$canonical_clone" remote set-url origin "$fork_bare"
    fi
    PATH="$fake_bin:$PATH" \
        VOICEINK_REPOSITORY_PATH="$canonical_clone" \
        VOICEINK_UPDATE_MANIFEST_PATH="$manifest_path" \
        VOICEINK_UPDATE_RESULT_PATH="$preparation_result" \
        VOICEINK_INSTALLED_FORK_COMMIT="$new_sha" \
        /bin/bash "$project_root/VoiceInk/Resources/prepare-local-update.sh" \
        > "$fixture_root/$scenario-prepare-output.log" 2>&1 \
        || { cat "$fixture_root/$scenario-prepare-output.log" >&2; exit 1; }

    [[ "$(/usr/bin/plutil -extract outcome raw "$preparation_result")" == "upToDate" ]]
    [[ "$(git --git-dir="$fork_bare" rev-parse refs/heads/main)" == "$new_sha" ]]
    [[ "$(git -C "$canonical_clone" rev-parse refs/heads/main)" == "$new_sha" ]]
    [[ ! -e "$manifest_path" ]]
    [[ ! -e "$staged_bundle" ]]
    if git -C "$canonical_clone" rev-parse --verify --quiet "$candidate_ref" >/dev/null; then
        printf 'install-local-update-test: %s retry left the candidate reference\n' "$scenario" >&2
        exit 1
    fi
    kill -0 "$pending_launched_pid"

    kill "$pending_launched_pid"
    /bin/rm -rf "$installed_bundle"
    /usr/bin/ditto "$backup_bundle" "$installed_bundle"
    git --git-dir="$fork_bare" update-ref refs/heads/main "$fork_base_sha" "$new_sha"
    git -C "$canonical_clone" switch --detach "$old_sha" >/dev/null 2>&1
    git -C "$canonical_clone" branch -f main "$old_sha"
    git -C "$canonical_clone" switch main >/dev/null 2>&1
    git -C "$canonical_clone" fetch origin main >/dev/null 2>&1
}

run_pending_publication fetch-failure VOICEINK_TEST_FAIL_FETCH_AFTER_HEALTH=1

pending_cleanup_path="$canonical_clone/edited-during-installation"
run_pending_publication clone-changed \
    VOICEINK_TEST_DIRTY_AFTER_HEALTH_PATH="$pending_cleanup_path"
grep -Fq "changed during preparation" "$fixture_root/clone-changed-output.log"
pending_cleanup_path=""

git -C "$canonical_clone" remote remove upstream
/bin/rm -f "$fake_bin/xcodebuild"
staged_bundle="$pending_original_staged_bundle"
stage_publishable_candidate newer-candidate

sleep 30 &
parent_pid=$!
: > "$launch_log"
: > "$publish_log"
prepare_recovery_intent
push_completed_path="$fixture_root/push-completed"
outcome_report="$fixture_root/install-outcome.plist"
outcome_order_log="$fixture_root/install-outcome-order.log"

PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_GIT_COMMAND="$fake_bin/git-require-health-before-push" \
    VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH="$application_support" \
    VOICEINK_UPDATE_PREFERENCES_PATH="$preferences" \
    VOICEINK_UPDATE_LAUNCHER="$fake_bin/launch-voiceink" \
    VOICEINK_UPDATE_ATOMIC_REPLACER="$fake_bin/replace-bundle" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_UPDATE_OUTCOME_RECORDER="$fake_bin/record-outcome" \
    VOICEINK_UPDATE_HEALTH_PATH="$health_path" \
    VOICEINK_UPDATE_HEALTH_TIMEOUT_SECONDS=2 \
    VOICEINK_UPDATE_STABILITY_SECONDS=1 \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
    VOICEINK_TEST_REQUIRED_HEALTH_PATH="$health_path" \
    VOICEINK_TEST_REQUIRED_PUBLISH_SHA="$new_sha" \
    VOICEINK_TEST_EXPECTED_LOCAL_MAIN_BEFORE_PUSH="$old_sha" \
    VOICEINK_TEST_PUBLISH_LOG="$publish_log" \
    VOICEINK_TEST_PUSH_COMPLETED_PATH="$push_completed_path" \
    VOICEINK_TEST_OUTCOME_REPORT="$outcome_report" \
    VOICEINK_TEST_OUTCOME_ORDER_LOG="$outcome_order_log" \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid"

if kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: approved parent survived installation\n' >&2
    exit 1
fi
parent_pid=""
[[ "$(< "$installed_bundle/Contents/version")" == "newer-candidate" ]]
[[ "$(< "$backup_bundle/Contents/version")" == "installed-before-update" ]]
[[ "$(< "$recovery_root/Application Support/state")" == "state-before-update" ]]
[[ "$(< "$recovery_root/Preferences.plist")" == "preferences-before-update" ]]
[[ "$(/usr/bin/plutil -extract previousForkCommit raw "$recovery_root/recovery.plist")" == "$old_sha" ]]
[[ "$(/usr/bin/plutil -extract candidateForkCommit raw "$recovery_root/recovery.plist")" == "$new_sha" ]]
[[ "$(/usr/bin/plutil -extract installInProgress raw "$recovery_root/recovery.plist")" == "false" ]]
[[ "$(stat -f '%Lp' "$recovery_root")" == "700" ]]
[[ "$(stat -f '%Lp' "$recovery_root/recovery.plist")" == "600" ]]
credential_generation="$(/usr/bin/plutil -extract credentialGeneration raw "$recovery_root/recovery.plist")"
[[ "$(< "$credential_create_log")" == "$credential_generation" ]]
[[ ! -e "$manifest_path" ]]
[[ ! -e "$staged_bundle" ]]
[[ "$(< "$launch_log")" == "$installed_bundle" ]]
[[ "$(< "$publish_log")" == "push-after-health" ]]
[[ -f "$push_completed_path" ]]
[[ "$(/usr/bin/plutil -extract outcome raw "$outcome_report")" == "succeeded" ]]
[[ "$(< "$outcome_order_log")" == "outcome" ]]
[[ "$(git --git-dir="$fork_bare" rev-parse refs/heads/main)" == "$new_sha" ]]
[[ "$(git -C "$canonical_clone" rev-parse refs/heads/main)" == "$new_sha" ]]
if git -C "$canonical_clone" rev-parse "$candidate_ref" >/dev/null 2>&1; then
    printf 'install-local-update-test: published candidate reference was not cleaned up\n' >&2
    exit 1
fi
launched_pid="$(/usr/bin/plutil -extract processIdentifier raw "$health_path")"

mkdir -p "$(dirname "$staged_bundle")"
/usr/bin/ditto "$installed_bundle" "$staged_bundle"

kill "$launched_pid"
launched_pid=""
/bin/rm -rf "$installed_bundle"
/usr/bin/ditto "$backup_bundle" "$installed_bundle"
/usr/bin/plutil -create xml1 "$manifest_path"
/usr/bin/plutil -insert forkCommit -string "$new_sha" "$manifest_path"
/usr/bin/plutil -insert upstreamCommit -string "$upstream_sha" "$manifest_path"
/usr/bin/plutil -insert bundlePath -string "$staged_bundle" "$manifest_path"
/usr/bin/plutil -insert preparedAt -date "2026-08-22T12:10:00Z" "$manifest_path"
printf 'known-good-data\n' > "$application_support/state"
printf 'known-good-preferences\n' > "$preferences"
printf 'obsolete\n' > "$recovery_root/obsolete-state"
: > "$launch_log"
sleep 30 &
parent_pid=$!

prepare_recovery_intent
set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_ATOMIC_REPLACER="$fake_bin/fail-replacement" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/no-mutation-replacement-output.log" 2>&1
no_mutation_replacement_status=$?
set -e

[[ "$no_mutation_replacement_status" -ne 0 ]]
if kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: approved parent survived replacement failure\n' >&2
    exit 1
fi
parent_pid=""
[[ "$(< "$installed_bundle/Contents/version")" == "installed-before-update" ]]
[[ -f "$recovery_root/obsolete-state" ]]
[[ ! -e "$recovery_root.pending" && ! -e "$recovery_root.previous" ]]
grep -Fqx "rollback:$installed_bundle" "$launch_log"

: > "$launch_log"
sleep 30 &
parent_pid=$!

prepare_recovery_intent
set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_ATOMIC_REPLACER="$fake_bin/replace-bundle" \
    VOICEINK_UPDATE_RECOVERY_MOVER="$fake_bin/fail-pending-recovery-move" \
    VOICEINK_TEST_RECOVERY_MOVE_FAILED="$fixture_root/recovery-move-failed" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/recovery-publish-output.log" 2>&1
recovery_publish_status=$?
set -e

[[ "$recovery_publish_status" -ne 0 ]]
if kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: approved parent survived recovery publish failure\n' >&2
    exit 1
fi
parent_pid=""
[[ ! -e "$recovery_root/obsolete-state" ]]
published_suppressed_sha="$(/usr/bin/plutil -extract suppressedForkCommit raw "$recovery_root/recovery.plist")" \
    || { tail -40 "$fixture_root/recovery-publish-output.log" >&2; printf 'install-local-update-test: recovered generation did not record suppression\n' >&2; exit 1; }
[[ "$published_suppressed_sha" == "$new_sha" ]]
[[ "$(< "$installed_bundle/Contents/version")" == "installed-before-update" ]]
grep -Fqx "rollback:$installed_bundle" "$launch_log"

: > "$launch_log"
sleep 30 &
parent_pid=$!

prepare_recovery_intent
set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH="$application_support" \
    VOICEINK_UPDATE_PREFERENCES_PATH="$preferences" \
    VOICEINK_UPDATE_PREFERENCES_RESTORER="$fake_bin/restore-preferences" \
    VOICEINK_UPDATE_CREDENTIAL_RESTORER="$fake_bin/restore-credentials" \
    VOICEINK_UPDATE_LAUNCHER="$fake_bin/launch-voiceink" \
    VOICEINK_UPDATE_ATOMIC_REPLACER="$fake_bin/replace-bundle" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_UPDATE_HEALTH_PATH="$health_path" \
    VOICEINK_UPDATE_HEALTH_TIMEOUT_SECONDS=2 \
    VOICEINK_UPDATE_STABILITY_SECONDS=1 \
    VOICEINK_TEST_HEALTH_FORK_OVERRIDE=ffffffffffffffffffffffffffffffffffffffff \
    VOICEINK_TEST_MUTATE_APPLICATION_SUPPORT="$application_support" \
    VOICEINK_TEST_MUTATE_PREFERENCES="$preferences" \
    VOICEINK_TEST_CREDENTIAL_LOG="$credential_log" \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/rollback-output.log" 2>&1
rollback_status=$?
set -e

[[ "$rollback_status" -ne 0 ]]
if kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: approved parent survived failed health verification\n' >&2
    exit 1
fi
parent_pid=""
[[ "$(< "$installed_bundle/Contents/version")" == "installed-before-update" ]]
[[ "$(< "$backup_bundle/Contents/version")" == "installed-before-update" ]]
[[ "$(< "$application_support/state")" == "known-good-data" ]]
[[ "$(< "$preferences")" == "known-good-preferences" ]]
[[ "$(< "$credential_log")" == "restored:$(/usr/bin/plutil -extract credentialGeneration raw "$recovery_root/recovery.plist")" ]]
rollback_suppressed_sha="$(/usr/bin/plutil -extract suppressedForkCommit raw "$recovery_root/recovery.plist")" \
    || { printf 'install-local-update-test: automatic rollback did not record suppression\n' >&2; exit 1; }
[[ "$rollback_suppressed_sha" == "$new_sha" ]]
[[ ! -e "$recovery_root/obsolete-state" ]]
grep -Fqx "$installed_bundle" "$launch_log"
grep -Fqx "rollback:$installed_bundle" "$launch_log"
grep -Fq "wrong fork provenance" "$fixture_root/rollback-output.log"
launched_pid="$(/usr/bin/plutil -extract processIdentifier raw "$health_path")"

launched_pid=""
: > "$launch_log"
: > "$outcome_order_log"
sleep 30 &
parent_pid=$!

prepare_recovery_intent
set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_LAUNCHER="$fake_bin/launch-voiceink" \
    VOICEINK_UPDATE_ATOMIC_REPLACER="$fake_bin/replace-bundle" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_UPDATE_OUTCOME_RECORDER="$fake_bin/record-outcome" \
    VOICEINK_UPDATE_HEALTH_PATH="$health_path" \
    VOICEINK_UPDATE_HEALTH_TIMEOUT_SECONDS=2 \
    VOICEINK_UPDATE_STABILITY_SECONDS=1 \
    VOICEINK_TEST_MICROPHONE_AUTHORIZED=false \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
    VOICEINK_TEST_OUTCOME_REPORT="$outcome_report" \
    VOICEINK_TEST_OUTCOME_ORDER_LOG="$outcome_order_log" \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/permission-regression-output.log" 2>&1
permission_regression_status=$?
set -e

[[ "$permission_regression_status" -ne 0 ]]
if kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: approved parent survived permission regression\n' >&2
    exit 1
fi
parent_pid=""
[[ "$(< "$installed_bundle/Contents/version")" == "installed-before-update" ]]
grep -Fq "lost microphone permission after replacement" "$fixture_root/permission-regression-output.log"
[[ "$(/usr/bin/plutil -extract outcome raw "$outcome_report")" == "failed" ]]
[[ "$(/usr/bin/plutil -extract failureStage raw "$outcome_report")" == "permission" ]]
[[ "$(/usr/bin/plutil -extract rollbackOutcome raw "$outcome_report")" == "succeeded" ]]
[[ "$(sed -n '1p' "$outcome_order_log")" == "outcome" ]]
[[ "$(sed -n '2p' "$outcome_order_log")" == "relaunch" ]]

: > "$launch_log"
pid_log="$fixture_root/timed-out-pid.log"
sleep 30 &
parent_pid=$!

prepare_recovery_intent
set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_LAUNCHER="$fake_bin/launch-voiceink" \
    VOICEINK_UPDATE_ATOMIC_REPLACER="$fake_bin/replace-bundle" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_UPDATE_HEALTH_PATH="$health_path" \
    VOICEINK_UPDATE_HEALTH_TIMEOUT_SECONDS=1 \
    VOICEINK_UPDATE_STABILITY_SECONDS=1 \
    VOICEINK_TEST_SKIP_HEALTH=1 \
    VOICEINK_TEST_PID_LOG="$pid_log" \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/timeout-output.log" 2>&1
timeout_status=$?
set -e

[[ "$timeout_status" -ne 0 ]]
if kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: approved parent survived health timeout\n' >&2
    exit 1
fi
parent_pid=""
timed_out_pid="$(< "$pid_log")"
if kill -0 "$timed_out_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: timed-out candidate survived rollback\n' >&2
    exit 1
fi
[[ "$(< "$installed_bundle/Contents/version")" == "installed-before-update" ]]
grep -Fqx "rollback:$installed_bundle" "$launch_log"
grep -Fq "did not report healthy" "$fixture_root/timeout-output.log"

: > "$launch_log"
sleep 30 &
parent_pid=$!

prepare_recovery_intent
set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_ATOMIC_REPLACER="$fake_bin/mutate-then-fail-replacement" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
    VOICEINK_TEST_MUTATION_LOG="$fixture_root/replacement-mutation.log" \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/replacement-output.log" 2>&1
replacement_status=$?
set -e

[[ "$replacement_status" -ne 0 ]]
if [[ "$(< "$fixture_root/replacement-mutation.log")" != "newer-candidate" ]]; then
    printf 'install-local-update-test: replacement fault did not mutate the installed bundle\n' >&2
    exit 1
fi
if kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: approved parent survived replacement failure\n' >&2
    exit 1
fi
parent_pid=""
if [[ "$(< "$installed_bundle/Contents/version")" != "installed-before-update" ]]; then
    printf 'install-local-update-test: replacement failure did not restore the installed bundle\n' >&2
    exit 1
fi
grep -Fqx "rollback:$installed_bundle" "$launch_log"

: > "$launch_log"
fetch_count="$fixture_root/fetch-count"
sleep 30 &
parent_pid=$!

prepare_recovery_intent
set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_GIT_COMMAND="$fake_bin/git-with-late-update" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_TEST_FETCH_COUNT="$fetch_count" \
    VOICEINK_TEST_SEED_CLONE="$seed_clone" \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
    /bin/bash "$project_root/VoiceInk/Resources/install-local-update.sh" \
    "$new_sha" \
    "$manifest_path" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/late-stale-output.log" 2>&1
late_stale_status=$?
set -e

[[ "$late_stale_status" -eq 75 ]]
if ! kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'install-local-update-test: approved parent was terminated before late stale detection\n' >&2
    exit 1
fi
[[ "$(< "$installed_bundle/Contents/version")" == "installed-before-update" ]]
[[ ! -s "$launch_log" ]]
grep -Fq "origin/main changed after preparation" "$fixture_root/late-stale-output.log"

printf 'install-local-update-test: PASS\n'
