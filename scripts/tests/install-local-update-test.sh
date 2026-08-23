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
grep -Fq "origin/main changed after preparation" "$fixture_root/origin-stale-output.log"

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
printf 'restored\n' > "$VOICEINK_TEST_CREDENTIAL_LOG"
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

chmod +x \
    "$fake_bin/codesign" \
    "$fake_bin/launch-voiceink" \
    "$fake_bin/relaunch-voiceink" \
    "$fake_bin/fail-snapshot" \
    "$fake_bin/restore-preferences" \
    "$fake_bin/restore-credentials" \
    "$fake_bin/mutate-then-fail-replacement" \
    "$fake_bin/replace-bundle" \
    "$fake_bin/git-with-late-update"

credential_log="$fixture_root/credential-restore.log"
export VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH="$application_support"
export VOICEINK_UPDATE_PREFERENCES_PATH="$preferences"
export VOICEINK_UPDATE_PREFERENCES_RESTORER="$fake_bin/restore-preferences"
export VOICEINK_UPDATE_CREDENTIAL_RESTORER="$fake_bin/restore-credentials"
export VOICEINK_TEST_CREDENTIAL_LOG="$credential_log"

staged_bundle="$fixture_root/staging/candidates/$new_sha/VoiceInk.app"
/usr/bin/plutil -replace forkCommit -string "$new_sha" "$manifest_path"
/usr/bin/plutil -replace upstreamCommit -string "$upstream_sha" "$manifest_path"
/usr/bin/plutil -replace bundlePath -string "$staged_bundle" "$manifest_path"

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
: > "$launch_log"

PATH="$fake_bin:$PATH" \
    VOICEINK_REPOSITORY_PATH="$canonical_clone" \
    VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH="$application_support" \
    VOICEINK_UPDATE_PREFERENCES_PATH="$preferences" \
    VOICEINK_UPDATE_LAUNCHER="$fake_bin/launch-voiceink" \
    VOICEINK_UPDATE_ATOMIC_REPLACER="$fake_bin/replace-bundle" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_UPDATE_HEALTH_PATH="$health_path" \
    VOICEINK_UPDATE_HEALTH_TIMEOUT_SECONDS=2 \
    VOICEINK_UPDATE_STABILITY_SECONDS=1 \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
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
[[ ! -e "$manifest_path" ]]
[[ "$(< "$launch_log")" == "$installed_bundle" ]]
launched_pid="$(/usr/bin/plutil -extract processIdentifier raw "$health_path")"

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
[[ "$(< "$credential_log")" == "restored" ]]
[[ "$(/usr/bin/plutil -extract suppressedForkCommit raw "$recovery_root/recovery.plist")" == "$new_sha" ]]
[[ ! -e "$recovery_root/obsolete-state" ]]
grep -Fqx "$installed_bundle" "$launch_log"
grep -Fqx "rollback:$installed_bundle" "$launch_log"
grep -Fq "wrong fork provenance" "$fixture_root/rollback-output.log"
launched_pid="$(/usr/bin/plutil -extract processIdentifier raw "$health_path")"

launched_pid=""
: > "$launch_log"
pid_log="$fixture_root/timed-out-pid.log"
sleep 30 &
parent_pid=$!

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
