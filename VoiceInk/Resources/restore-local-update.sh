#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

automatic=false
if [[ "${1:-}" == "--automatic" ]]; then
    [[ "$#" -eq 3 ]] \
        || fail "Usage: restore-local-update.sh --automatic TARGET_BUNDLE BACKUP_BUNDLE"
    automatic=true
    target_bundle="$2"
    backup_bundle="$3"
    parent_pid=""
else
    [[ "$#" -eq 3 ]] \
        || fail "Usage: restore-local-update.sh TARGET_BUNDLE BACKUP_BUNDLE PARENT_PID"
    target_bundle="$1"
    backup_bundle="$2"
    parent_pid="$3"
fi
recovery_root="$(dirname "$backup_bundle")"
recovery_state="$recovery_root/recovery.plist"
application_support="${VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH:-$HOME/Library/Application Support/com.prakashjoshipax.VoiceInk}"
preferences="${VOICEINK_UPDATE_PREFERENCES_PATH:-$HOME/Library/Preferences/com.prakashjoshipax.VoiceInk.plist}"
parent_exit_timeout="${VOICEINK_UPDATE_PARENT_EXIT_TIMEOUT_SECONDS:-30}"
relauncher="${VOICEINK_UPDATE_RELAUNCHER:-}"
preferences_restorer="${VOICEINK_UPDATE_PREFERENCES_RESTORER:-}"
credential_restorer="${VOICEINK_UPDATE_CREDENTIAL_RESTORER:-}"

[[ -d "$target_bundle" ]] || fail "The installed VoiceInk bundle is missing."
[[ -d "$backup_bundle" ]] || fail "The previous VoiceInk bundle is missing."
[[ -f "$recovery_state" ]] || fail "The previous recovery state is missing."
[[ -d "$recovery_root/Application Support" ]] \
    || fail "The previous Application Support snapshot is missing."
[[ -f "$recovery_root/Preferences.plist" ]] \
    || fail "The previous preferences snapshot is missing."
if [[ "$automatic" == false ]]; then
    [[ "$parent_pid" =~ ^[1-9][0-9]*$ ]] || fail "The VoiceInk process identifier is invalid."
    kill -0 "$parent_pid" 2>/dev/null || fail "VoiceInk is no longer running."
fi

candidate_sha="$(/usr/bin/plutil -extract VoiceInkForkCommit raw "$target_bundle/Contents/Info.plist" 2>/dev/null)" \
    || fail "The installed VoiceInk bundle has no fork provenance."
recorded_candidate="$(/usr/bin/plutil -extract candidateForkCommit raw "$recovery_state" 2>/dev/null)" \
    || fail "The recovery state has no candidate provenance."
[[ "$candidate_sha" == "$recorded_candidate" ]] \
    || fail "The recovery state does not belong to the installed VoiceInk version."

umask 077
transaction_root="$(mktemp -d "${TMPDIR:-/tmp}/voiceink-restore.XXXXXX")"
restored_bundle="$transaction_root/VoiceInk.app"
restored_application_support="$transaction_root/Application Support"

cleanup() {
    rm -rf "$transaction_root"
}
trap cleanup EXIT

/usr/bin/ditto "$backup_bundle" "$restored_bundle"
codesign --verify --deep --strict "$restored_bundle" \
    || fail "The previous VoiceInk bundle failed signature validation."

if [[ -n "${VOICEINK_UPDATE_STATE_SNAPSHOTTER:-}" ]]; then
    "$VOICEINK_UPDATE_STATE_SNAPSHOTTER" \
        "$recovery_root/Application Support" \
        "$restored_application_support"
else
    /bin/cp -cRp "$recovery_root/Application Support" "$restored_application_support" \
        || fail "VoiceInk could not clone the previous Application Support state."
fi
/bin/rm -rf "$restored_application_support/Updater"

if [[ "$automatic" == false ]]; then
    kill -TERM "$parent_pid" || fail "VoiceInk could not be terminated for restoration."
    for ((attempt = 0; attempt < parent_exit_timeout * 10; attempt++)); do
        if ! kill -0 "$parent_pid" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    kill -0 "$parent_pid" 2>/dev/null \
        && fail "VoiceInk did not terminate before the restoration timeout."
fi

application_support_parent="$(dirname "$application_support")"
preferences_parent="$(dirname "$preferences")"
failed_application_support="$transaction_root/rejected-Application-Support"
failed_bundle="$transaction_root/rejected-VoiceInk.app"
mkdir -p "$application_support_parent" "$preferences_parent"

if [[ -e "$application_support" ]]; then
    mv "$application_support" "$failed_application_support"
fi
mv "$restored_application_support" "$application_support"

if [[ -n "$preferences_restorer" ]]; then
    "$preferences_restorer" "$recovery_root/Preferences.plist" "$preferences"
else
    /usr/bin/defaults import com.prakashjoshipax.VoiceInk "$recovery_root/Preferences.plist" >/dev/null
fi

mv "$target_bundle" "$failed_bundle"
mv "$restored_bundle" "$target_bundle"

if [[ -n "$credential_restorer" ]]; then
    "$credential_restorer"
else
    restored_executable="$target_bundle/Contents/MacOS/VoiceInk"
    [[ -x "$restored_executable" ]] || fail "The previous VoiceInk executable is missing."
    "$restored_executable" --voiceink-restore-update-credentials
fi

if /usr/bin/plutil -extract suppressedForkCommit raw "$recovery_state" >/dev/null 2>&1; then
    /usr/bin/plutil -replace suppressedForkCommit -string "$candidate_sha" "$recovery_state"
else
    /usr/bin/plutil -insert suppressedForkCommit -string "$candidate_sha" "$recovery_state"
fi

if [[ -n "$relauncher" ]]; then
    "$relauncher" "$target_bundle"
else
    /usr/bin/open -n "$target_bundle"
fi

printf 'Restored VoiceInk %s and suppressed rejected candidate %s\n' \
    "$(/usr/bin/plutil -extract previousForkCommit raw "$recovery_state")" \
    "$candidate_sha"
