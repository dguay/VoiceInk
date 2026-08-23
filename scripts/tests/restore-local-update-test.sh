#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/voiceink-restore-update-test.XXXXXX")"
parent_pid=""

cleanup() {
    if [[ -n "$parent_pid" ]]; then
        kill "$parent_pid" >/dev/null 2>&1 || true
    fi
    rm -rf "$fixture_root"
}
trap cleanup EXIT

candidate_sha="1111111111111111111111111111111111111111"
previous_sha="2222222222222222222222222222222222222222"
credential_generation="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
installed_bundle="$fixture_root/Applications/VoiceInk.app"
recovery_root="$fixture_root/Recovery"
backup_bundle="$recovery_root/VoiceInk.app"
application_support="$fixture_root/Library/Application Support/com.prakashjoshipax.VoiceInk"
preferences="$fixture_root/Library/Preferences/com.prakashjoshipax.VoiceInk.plist"
launch_log="$fixture_root/launch.log"
credential_log="$fixture_root/credentials.log"
fake_bin="$fixture_root/bin"

mkdir -p \
    "$installed_bundle/Contents" \
    "$backup_bundle/Contents" \
    "$application_support" \
    "$recovery_root/Application Support" \
    "$(dirname "$preferences")" \
    "$fake_bin"
printf 'candidate\n' > "$installed_bundle/Contents/version"
printf 'previous\n' > "$backup_bundle/Contents/version"
printf 'candidate-data\n' > "$application_support/state"
printf 'previous-data\n' > "$recovery_root/Application Support/state"
printf 'candidate-preferences\n' > "$preferences"
printf 'previous-preferences\n' > "$recovery_root/Preferences.plist"

/usr/bin/plutil -create xml1 "$installed_bundle/Contents/Info.plist"
/usr/bin/plutil -insert VoiceInkForkCommit -string "$candidate_sha" "$installed_bundle/Contents/Info.plist"
/usr/bin/plutil -create xml1 "$backup_bundle/Contents/Info.plist"
/usr/bin/plutil -insert VoiceInkForkCommit -string "$previous_sha" "$backup_bundle/Contents/Info.plist"
/usr/bin/plutil -create xml1 "$recovery_root/recovery.plist"
/usr/bin/plutil -insert previousForkCommit -string "$previous_sha" "$recovery_root/recovery.plist"
/usr/bin/plutil -insert candidateForkCommit -string "$candidate_sha" "$recovery_root/recovery.plist"
/usr/bin/plutil -insert credentialGeneration -string "$credential_generation" "$recovery_root/recovery.plist"

cat > "$fake_bin/restore-preferences" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
/bin/cp "$1" "$2"
EOF

cat > "$fake_bin/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -d "${@: -1}" ]]
EOF

cat > "$fake_bin/restore-credentials" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'restored:%s\n' "$1" > "$VOICEINK_TEST_CREDENTIAL_LOG"
EOF

cat > "$fake_bin/fail-credentials" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF

cat > "$fake_bin/fail-snapshot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF

cat > "$fake_bin/relaunch-voiceink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" > "$VOICEINK_TEST_LAUNCH_LOG"
EOF

chmod +x \
    "$fake_bin/codesign" \
    "$fake_bin/restore-preferences" \
    "$fake_bin/restore-credentials" \
    "$fake_bin/fail-credentials" \
    "$fake_bin/fail-snapshot" \
    "$fake_bin/relaunch-voiceink"

sleep 30 &
parent_pid=$!

PATH="$fake_bin:$PATH" \
    VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH="$application_support" \
    VOICEINK_UPDATE_PREFERENCES_PATH="$preferences" \
    VOICEINK_UPDATE_PREFERENCES_RESTORER="$fake_bin/restore-preferences" \
    VOICEINK_UPDATE_CREDENTIAL_RESTORER="$fake_bin/restore-credentials" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_TEST_CREDENTIAL_LOG="$credential_log" \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
    /bin/bash "$project_root/VoiceInk/Resources/restore-local-update.sh" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid"

if kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'restore-local-update-test: VoiceInk remained running during restore\n' >&2
    exit 1
fi
parent_pid=""

[[ "$(< "$installed_bundle/Contents/version")" == "previous" ]]
[[ "$(< "$application_support/state")" == "previous-data" ]]
[[ "$(< "$preferences")" == "previous-preferences" ]]
[[ "$(< "$credential_log")" == "restored:$credential_generation" ]]
[[ "$(< "$launch_log")" == "$installed_bundle" ]]
[[ "$(/usr/bin/plutil -extract suppressedForkCommit raw "$recovery_root/recovery.plist")" == "$candidate_sha" ]]
[[ -d "$backup_bundle" ]]
[[ -d "$recovery_root/Application Support" ]]

printf 'candidate\n' > "$installed_bundle/Contents/version"
/usr/bin/plutil -replace VoiceInkForkCommit -string "$candidate_sha" "$installed_bundle/Contents/Info.plist"
printf 'candidate-data\n' > "$application_support/state"
printf 'candidate-preferences\n' > "$preferences"
: > "$launch_log"
sleep 30 &
parent_pid=$!

set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH="$application_support" \
    VOICEINK_UPDATE_PREFERENCES_PATH="$preferences" \
    VOICEINK_UPDATE_PREFERENCES_RESTORER="$fake_bin/restore-preferences" \
    VOICEINK_UPDATE_CREDENTIAL_RESTORER="$fake_bin/fail-credentials" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
    /bin/bash "$project_root/VoiceInk/Resources/restore-local-update.sh" \
    "$installed_bundle" \
    "$backup_bundle" \
    "$parent_pid" \
    > "$fixture_root/failed-restore.log" 2>&1
failed_restore_status=$?
set -e

[[ "$failed_restore_status" -ne 0 ]]
if kill -0 "$parent_pid" >/dev/null 2>&1; then
    printf 'restore-local-update-test: VoiceInk remained running during failed restore\n' >&2
    exit 1
fi
parent_pid=""
[[ "$(< "$installed_bundle/Contents/version")" == "candidate" ]]
[[ "$(< "$application_support/state")" == "candidate-data" ]]
[[ "$(< "$preferences")" == "candidate-preferences" ]]
[[ ! -s "$launch_log" ]]
grep -Fq "could not prove a consistent" "$fixture_root/failed-restore.log"

: > "$launch_log"
set +e
PATH="$fake_bin:$PATH" \
    VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH="$application_support" \
    VOICEINK_UPDATE_PREFERENCES_PATH="$preferences" \
    VOICEINK_UPDATE_STATE_SNAPSHOTTER="$fake_bin/fail-snapshot" \
    VOICEINK_UPDATE_RELAUNCHER="$fake_bin/relaunch-voiceink" \
    VOICEINK_TEST_LAUNCH_LOG="$launch_log" \
    /bin/bash "$project_root/VoiceInk/Resources/restore-local-update.sh" \
    --automatic \
    "$installed_bundle" \
    "$backup_bundle" \
    > "$fixture_root/failed-automatic-staging.log" 2>&1
automatic_staging_status=$?
set -e

[[ "$automatic_staging_status" -ne 0 ]]
[[ "$(< "$launch_log")" == "$installed_bundle" ]]

printf 'restore-local-update-test: PASS\n'
