#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

stale() {
    printf 'Update stale: %s\n' "$*" >&2
    exit 75
}

[[ "$#" -eq 5 ]] \
    || fail "Usage: install-local-update.sh APPROVED_SHA MANIFEST TARGET_BUNDLE BACKUP_BUNDLE PARENT_PID"

approved_sha="$1"
manifest_path="$2"
target_bundle="$3"
backup_bundle="$4"
parent_pid="$5"
git_command="${VOICEINK_UPDATE_GIT_COMMAND:-git}"
credential_generation="${VOICEINK_UPDATE_CREDENTIAL_GENERATION:-}"
credential_snapshot_deleter="${VOICEINK_UPDATE_CREDENTIAL_SNAPSHOT_DELETER:-}"

if [[ -n "$credential_generation" ]]; then
    [[ "$credential_generation" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
        || fail "VoiceInk did not provide a valid credential recovery generation."
    credential_generation="$(printf '%s' "$credential_generation" | /usr/bin/tr '[:upper:]' '[:lower:]')"

    cleanup_preflight_snapshot() {
        result=$?
        trap - EXIT
        if [[ "$result" -ne 0 ]]; then
            if [[ -n "$credential_snapshot_deleter" ]]; then
                "$credential_snapshot_deleter" "$credential_generation" \
                    || { printf 'Error: VoiceInk could not remove the preflight credential snapshot.\n' >&2; result=2; }
            else
                preflight_executable="$target_bundle/Contents/MacOS/VoiceInk"
                if [[ ! -x "$preflight_executable" ]] \
                    || ! "$preflight_executable" --voiceink-delete-update-credentials "$credential_generation"; then
                    printf 'Error: VoiceInk could not remove the preflight credential snapshot.\n' >&2
                    result=2
                fi
            fi
            preflight_recovery_root="$(dirname "$backup_bundle")"
            preflight_pending="$preflight_recovery_root.pending"
            if [[ -d "$preflight_pending" ]]; then
                if ! pending_generation="$(/usr/bin/plutil -extract credentialGeneration raw "$preflight_pending/recovery.plist" 2>/dev/null)"; then
                    printf 'Error: VoiceInk could not validate the preflight recovery intent.\n' >&2
                    result=2
                elif [[ "$pending_generation" == "$credential_generation" ]] \
                    && ! /bin/rm -rf "$preflight_pending"; then
                    printf 'Error: VoiceInk could not remove the preflight recovery intent.\n' >&2
                    result=2
                fi
            fi
        fi
        exit "$result"
    }
    trap cleanup_preflight_snapshot EXIT
fi

[[ -f "$manifest_path" ]] || stale "the approved candidate is no longer staged."

manifest_sha="$(/usr/bin/plutil -extract forkCommit raw "$manifest_path" 2>/dev/null)" \
    || stale "the staged candidate manifest is invalid."
[[ "$manifest_sha" == "$approved_sha" ]] \
    || stale "the approved candidate is no longer staged."

repository_path="${VOICEINK_REPOSITORY_PATH:-}"
if [[ -z "$repository_path" ]]; then
    repository_path="$("$git_command" config --global --get voiceink.repositoryPath 2>/dev/null || true)"
fi
[[ -n "$repository_path" ]] \
    || fail "No VoiceInk clone is registered. Run 'make bootstrap' from the clone first."
repository_path="$("$git_command" -C "$repository_path" rev-parse --show-toplevel 2>/dev/null)" \
    || fail "The registered VoiceInk clone is unavailable. Run 'make bootstrap' again."

revalidate_fork() {
    "$git_command" -C "$repository_path" fetch origin main
    latest_fork_sha="$("$git_command" -C "$repository_path" rev-parse refs/remotes/origin/main)" \
        || fail "The fetched fork does not have origin/main."
    [[ "$latest_fork_sha" == "$approved_sha" ]] \
        || stale "origin/main changed after preparation. Prepare the new candidate before restarting."
}

revalidate_fork

manifest_upstream_sha="$(/usr/bin/plutil -extract upstreamCommit raw "$manifest_path" 2>/dev/null)" \
    || fail "The staged candidate manifest has no upstream provenance."
staged_bundle="$(/usr/bin/plutil -extract bundlePath raw "$manifest_path" 2>/dev/null)" \
    || fail "The staged candidate manifest has no bundle path."

[[ -d "$staged_bundle" ]] || fail "The staged candidate bundle is missing."
[[ -d "$target_bundle" ]] || fail "The installed VoiceInk bundle is missing."
[[ "$target_bundle" == *.app && "$backup_bundle" == *.app ]] \
    || fail "The transaction paths must identify application bundles."
[[ "$parent_pid" =~ ^[1-9][0-9]*$ ]] || fail "The VoiceInk process identifier is invalid."
kill -0 "$parent_pid" 2>/dev/null || fail "VoiceInk is no longer running."

staged_info="$staged_bundle/Contents/Info.plist"
[[ "$(/usr/bin/plutil -extract VoiceInkForkCommit raw "$staged_info" 2>/dev/null)" == "$approved_sha" ]] \
    || fail "The staged bundle has the wrong fork provenance."
[[ "$(/usr/bin/plutil -extract VoiceInkUpstreamCommit raw "$staged_info" 2>/dev/null)" == "$manifest_upstream_sha" ]] \
    || fail "The staged bundle has the wrong upstream provenance."
[[ "$(/usr/bin/plutil -extract VoiceInkUpdaterKind raw "$staged_info" 2>/dev/null)" == "fork" ]] \
    || fail "The staged bundle does not contain the local fork updater."
codesign --verify --deep --strict "$staged_bundle" \
    || fail "The staged candidate bundle failed signature validation."
[[ -n "$credential_generation" ]] \
    || fail "VoiceInk did not provide a credential recovery generation."

target_parent="$(dirname "$target_bundle")"
backup_parent="$(dirname "$backup_bundle")"
stage_root="$(dirname "$manifest_path")"
recovery_root="$backup_parent"
recovery_parent="$(dirname "$recovery_root")"
application_support="${VOICEINK_UPDATE_APPLICATION_SUPPORT_PATH:-$HOME/Library/Application Support/com.prakashjoshipax.VoiceInk}"
preferences="${VOICEINK_UPDATE_PREFERENCES_PATH:-$HOME/Library/Preferences/com.prakashjoshipax.VoiceInk.plist}"
restoration_script="${VOICEINK_UPDATE_RESTORATION_SCRIPT:-$(dirname "$0")/restore-local-update.sh}"
candidate_temporary="$target_parent/.VoiceInk.install.$$"
retired_bundle="$target_parent/.VoiceInk.retired.$$"
recovery_temporary="$recovery_root.pending"
previous_recovery="$recovery_root.previous"
health_path="${VOICEINK_UPDATE_HEALTH_PATH:-$stage_root/install-health.plist}"
launcher="${VOICEINK_UPDATE_LAUNCHER:-}"
relauncher="${VOICEINK_UPDATE_RELAUNCHER:-}"
atomic_replacer="${VOICEINK_UPDATE_ATOMIC_REPLACER:-}"
credential_snapshot_creator="${VOICEINK_UPDATE_CREDENTIAL_SNAPSHOT_CREATOR:-}"
recovery_mover="${VOICEINK_UPDATE_RECOVERY_MOVER:-}"
health_timeout="${VOICEINK_UPDATE_HEALTH_TIMEOUT_SECONDS:-30}"
stability_seconds="${VOICEINK_UPDATE_STABILITY_SECONDS:-10}"
parent_exit_timeout="${VOICEINK_UPDATE_PARENT_EXIT_TIMEOUT_SECONDS:-30}"
parent_terminated=false
launched_pid=""
recovery_published=false
credential_snapshot_created=true

launch_candidate() {
    if [[ -n "$launcher" ]]; then
        "$launcher" "$target_bundle" "$health_path"
    else
        executable="$target_bundle/Contents/MacOS/VoiceInk"
        [[ -x "$executable" ]] || fail "The installed app has no executable."
        "$executable" --voiceink-update-health-path "$health_path" >/dev/null 2>&1 &
        printf '%s\n' "$!"
    fi
}

replace_bundle_atomically() {
    if [[ -n "$atomic_replacer" ]]; then
        "$atomic_replacer" "$target_bundle" "$candidate_temporary" "$retired_bundle"
        return
    fi
    /usr/bin/swift - "$target_bundle" "$candidate_temporary" "$(basename "$retired_bundle")" <<'SWIFT'
import Foundation

let arguments = CommandLine.arguments
let target = URL(fileURLWithPath: arguments[1])
let candidate = URL(fileURLWithPath: arguments[2])
_ = try FileManager.default.replaceItemAt(
    target,
    withItemAt: candidate,
    backupItemName: arguments[3],
    options: [.withoutDeletingBackupItem]
)
SWIFT
}

relaunch_previous() {
    if [[ -n "$relauncher" ]]; then
        "$relauncher" "$target_bundle"
    else
        /usr/bin/open -n "$target_bundle"
    fi
}

create_credential_snapshot() {
    if [[ -n "$credential_snapshot_creator" ]]; then
        "$credential_snapshot_creator" "$credential_generation"
        return
    fi
    current_executable="$target_bundle/Contents/MacOS/VoiceInk"
    [[ -x "$current_executable" ]] || fail "The installed VoiceInk executable is missing."
    "$current_executable" --voiceink-create-update-credentials "$credential_generation"
}

delete_credential_snapshot() {
    generation_identifier="$1"
    if [[ -n "$credential_snapshot_deleter" ]]; then
        "$credential_snapshot_deleter" "$generation_identifier"
        return
    fi
    current_executable="$target_bundle/Contents/MacOS/VoiceInk"
    [[ -x "$current_executable" ]] || fail "The installed VoiceInk executable is missing."
    "$current_executable" --voiceink-delete-update-credentials "$generation_identifier"
}

move_recovery_directory() {
    if [[ -n "$recovery_mover" ]]; then
        "$recovery_mover" "$1" "$2"
    else
        mv "$1" "$2"
    fi
}

stop_launched_candidate() {
    candidate_stopped=true
    [[ "$launched_pid" =~ ^[1-9][0-9]*$ ]] || return
    if kill -0 "$launched_pid" 2>/dev/null && ! kill -TERM "$launched_pid"; then
        candidate_stopped=false
    fi
    for ((attempt = 0; attempt < parent_exit_timeout * 10; attempt++)); do
        kill -0 "$launched_pid" 2>/dev/null || return
        sleep 0.1
    done
    kill -KILL "$launched_pid" || candidate_stopped=false
    for ((attempt = 0; attempt < parent_exit_timeout * 10; attempt++)); do
        kill -0 "$launched_pid" 2>/dev/null || return
        sleep 0.1
    done
    candidate_stopped=false
    if [[ "$candidate_stopped" == false ]]; then
        printf 'Error: VoiceInk could not stop the rejected candidate before rollback.\n' >&2
    fi
}

run_automatic_rollback() {
    rollback_bundle="$backup_bundle"
    [[ "$recovery_published" == true ]] || rollback_bundle="$recovery_temporary/VoiceInk.app"
    rollback_succeeded=false
    if [[ "$candidate_stopped" == true && -d "$rollback_bundle" ]] \
        && /bin/bash "$restoration_script" --automatic "$target_bundle" "$rollback_bundle"; then
        rollback_succeeded=true
        return
    fi
    printf 'Error: Automatic rollback could not restore a consistent local state.\n' >&2
    result=2
}

publish_recovered_pending_generation() {
    [[ "$rollback_succeeded" == true && "$rollback_bundle" == "$recovery_temporary/VoiceInk.app" ]] || return
    if [[ -d "$recovery_root" && ! -d "$previous_recovery" ]] \
        && ! move_recovery_directory "$recovery_root" "$previous_recovery"; then
        printf 'Error: VoiceInk could not preserve the prior recovery generation during rollback.\n' >&2
        result=2
        return
    fi
    if [[ ! -d "$recovery_root" ]] && ! move_recovery_directory "$recovery_temporary" "$recovery_root"; then
        printf 'Error: VoiceInk could not publish the recovered generation after rollback.\n' >&2
        result=2
        return
    fi
    recovery_published=true
}

remove_previous_recovery_generation() {
    [[ "$rollback_succeeded" == true && -d "$previous_recovery" ]] || return
    if ! obsolete_generation="$(/usr/bin/plutil -extract credentialGeneration raw "$previous_recovery/recovery.plist" 2>/dev/null)" \
        || ! delete_credential_snapshot "$obsolete_generation" \
        || ! /bin/rm -rf "$previous_recovery"; then
        printf 'Error: VoiceInk could not remove the superseded recovery generation.\n' >&2
        result=2
    fi
}

restore_previous_recovery_directory() {
    [[ "$result" -ne 0 && "$installed_after_failure" != "$approved_sha" && -d "$previous_recovery" ]] || return
    if { [[ -d "$recovery_root" ]] && ! /bin/rm -rf "$recovery_root"; } \
        || ! move_recovery_directory "$previous_recovery" "$recovery_root"; then
        printf 'Error: VoiceInk could not restore the prior recovery generation.\n' >&2
        result=2
    fi
}

cleanup_installation_artifacts() {
    if ! /bin/rm -rf "$candidate_temporary" "$retired_bundle"; then
        printf 'Error: VoiceInk could not clean up the failed installation transaction.\n' >&2
        result=2
    fi
    if [[ "$installed_after_failure" != "$approved_sha" ]] && ! /bin/rm -rf "$recovery_temporary"; then
        printf 'Error: VoiceInk could not clean up the pending recovery generation.\n' >&2
        result=2
    fi
}

finish_transaction() {
    result=$?
    trap - EXIT
    set +e
    installed_after_failure="$(/usr/bin/plutil -extract VoiceInkForkCommit raw "$target_bundle/Contents/Info.plist" 2>/dev/null || true)"

    if [[ "$result" -ne 0 && "$installed_after_failure" == "$approved_sha" ]]; then
        stop_launched_candidate
        run_automatic_rollback
        publish_recovered_pending_generation
        remove_previous_recovery_generation
    elif [[ "$result" -ne 0 && "$parent_terminated" == true ]] && ! relaunch_previous; then
        printf 'Error: VoiceInk could not relaunch the previous version after the failed update.\n' >&2
        result=2
    fi

    restore_previous_recovery_directory
    if [[ "$result" -ne 0 && "$installed_after_failure" != "$approved_sha" && "$credential_snapshot_created" == true ]] \
        && ! delete_credential_snapshot "$credential_generation"; then
        printf 'Error: VoiceInk could not remove the incomplete credential recovery generation.\n' >&2
        result=2
    fi
    cleanup_installation_artifacts
    exit "$result"
}
trap finish_transaction EXIT

# Reserve enough logical capacity for the app and mutable state even though APFS
# clones initially share blocks. Later writes must not exhaust the recovery volume.
required_disk_kib=0
for snapshot_source in "$application_support" "$preferences" "$target_bundle" "$staged_bundle"; do
    if [[ -e "$snapshot_source" ]]; then
        source_kib="$(/usr/bin/du -sk "$snapshot_source" | /usr/bin/awk '{print $1}')"
        required_disk_kib=$((required_disk_kib + source_kib))
    fi
done
available_disk_kib="${VOICEINK_UPDATE_AVAILABLE_DISK_KIB:-}"
if [[ -z "$available_disk_kib" ]]; then
    available_disk_kib="$(/bin/df -Pk "$recovery_parent" | /usr/bin/awk 'NR == 2 {print $4}')"
fi
[[ "$available_disk_kib" =~ ^[0-9]+$ && "$available_disk_kib" -ge "$required_disk_kib" ]] \
    || fail "VoiceInk does not have sufficient disk space for a complete recovery snapshot."

mkdir -p "$target_parent"
[[ -d "$recovery_temporary" && ! -e "$previous_recovery" ]] \
    || fail "VoiceInk could not find the matching recovery intent. Relaunch VoiceInk before retrying the update."
intent_previous_sha="$(/usr/bin/plutil -extract previousForkCommit raw "$recovery_temporary/recovery.plist" 2>/dev/null)" \
    || fail "VoiceInk found an invalid recovery intent."
intent_candidate_sha="$(/usr/bin/plutil -extract candidateForkCommit raw "$recovery_temporary/recovery.plist" 2>/dev/null)" \
    || fail "VoiceInk found an invalid recovery intent."
intent_credential_generation="$(/usr/bin/plutil -extract credentialGeneration raw "$recovery_temporary/recovery.plist" 2>/dev/null)" \
    || fail "VoiceInk found an invalid recovery intent."
previous_fork_sha="$(/usr/bin/plutil -extract VoiceInkForkCommit raw "$target_bundle/Contents/Info.plist" 2>/dev/null)" \
    || fail "The installed VoiceInk bundle has no fork provenance."
[[ "$intent_previous_sha" == "$previous_fork_sha" \
    && "$intent_candidate_sha" == "$approved_sha" \
    && "$intent_credential_generation" == "$credential_generation" ]] \
    || fail "VoiceInk found a recovery intent for a different update generation."
/usr/bin/ditto "$staged_bundle" "$candidate_temporary"
codesign --verify --deep --strict "$candidate_temporary" \
    || fail "The installation copy failed signature validation."

umask 077
chmod 700 "$recovery_temporary"
/usr/bin/ditto "$target_bundle" "$recovery_temporary/VoiceInk.app"

# Close the fetch-to-install race while the approved app can still prepare a
# replacement candidate when the fork advances.
revalidate_fork

kill -TERM "$parent_pid" || fail "VoiceInk could not be terminated for installation."
for ((attempt = 0; attempt < parent_exit_timeout * 10; attempt++)); do
    if ! kill -0 "$parent_pid" 2>/dev/null; then
        break
    fi
    sleep 0.1
done
if kill -0 "$parent_pid" 2>/dev/null; then
    fail "VoiceInk did not terminate before the installation timeout."
fi
parent_terminated=true

# The normal app is stopped before this short-lived command starts, so Keychain,
# Application Support, and preferences all describe the same quiescent generation.
# Refresh the pre-quit snapshot after the parent exits. This overwrites the same
# generation and closes the gap between the app's quit request and state cloning.
create_credential_snapshot \
    || fail "VoiceInk could not create the credential recovery snapshot."
credential_snapshot_created=true

if [[ -n "${VOICEINK_UPDATE_STATE_SNAPSHOTTER:-}" ]]; then
    "$VOICEINK_UPDATE_STATE_SNAPSHOTTER" \
        "$application_support" \
        "$recovery_temporary/Application Support" \
        || fail "VoiceInk could not create a consistent copy-on-write state snapshot."
else
    /bin/cp -cRp "$application_support" "$recovery_temporary/Application Support" \
        || fail "VoiceInk could not create a consistent copy-on-write state snapshot."
fi

if [[ -f "$preferences" ]]; then
    /bin/cp -cp "$preferences" "$recovery_temporary/Preferences.plist" \
        || fail "VoiceInk could not create a copy-on-write preferences snapshot."
else
    /usr/bin/defaults export com.prakashjoshipax.VoiceInk "$recovery_temporary/Preferences.plist" >/dev/null \
        || fail "VoiceInk could not export a consistent preferences snapshot."
fi

# Replace the bundle before publishing the new recovery. The fixed pending path
# survives a helper crash and lets the next launch finish or unwind publication.
replace_bundle_atomically

if [[ -d "$recovery_root" ]]; then
    move_recovery_directory "$recovery_root" "$previous_recovery"
fi
move_recovery_directory "$recovery_temporary" "$recovery_root"
recovery_published=true

/bin/rm -f "$health_path"
launched_pid="$(launch_candidate)"
[[ "$launched_pid" =~ ^[1-9][0-9]*$ ]] \
    || fail "The installed app did not return a valid process identifier."

for ((attempt = 0; attempt < health_timeout * 10; attempt++)); do
    if [[ -f "$health_path" ]]; then
        break
    fi
    sleep 0.1
done
[[ -f "$health_path" ]] || fail "The installed app did not report healthy before the timeout."

health_fork_sha="$(/usr/bin/plutil -extract forkCommit raw "$health_path" 2>/dev/null)" \
    || fail "The installed app reported an invalid health handshake."
health_upstream_sha="$(/usr/bin/plutil -extract upstreamCommit raw "$health_path" 2>/dev/null)" \
    || fail "The installed app reported an invalid health handshake."
health_updater_kind="$(/usr/bin/plutil -extract updaterKind raw "$health_path" 2>/dev/null)" \
    || fail "The installed app reported an invalid health handshake."
reported_pid="$(/usr/bin/plutil -extract processIdentifier raw "$health_path" 2>/dev/null)" \
    || fail "The installed app reported an invalid process identifier."

[[ "$health_fork_sha" == "$approved_sha" ]] \
    || fail "The installed app reported the wrong fork provenance."
[[ "$health_upstream_sha" == "$manifest_upstream_sha" ]] \
    || fail "The installed app reported the wrong upstream provenance."
[[ "$health_updater_kind" == "fork" ]] \
    || fail "The installed app reported the wrong updater kind."
[[ "$reported_pid" =~ ^[1-9][0-9]*$ && "$reported_pid" == "$launched_pid" ]] \
    || fail "The installed app reported an invalid process identifier."

for ((attempt = 0; attempt < stability_seconds * 10; attempt++)); do
    kill -0 "$launched_pid" 2>/dev/null \
        || fail "The installed app exited during the stability window."
    sleep 0.1
done

/usr/bin/plutil -replace installInProgress -bool false "$recovery_root/recovery.plist" \
    || fail "VoiceInk could not commit the successful installation state."

/bin/rm -rf "$retired_bundle"
if [[ -d "$previous_recovery" ]]; then
    previous_credential_generation="$(/usr/bin/plutil -extract credentialGeneration raw "$previous_recovery/recovery.plist" 2>/dev/null)" \
        || fail "VoiceInk could not read the obsolete credential recovery snapshot."
    delete_credential_snapshot "$previous_credential_generation" \
        || fail "VoiceInk could not remove the obsolete credential recovery snapshot."
    /bin/rm -rf "$previous_recovery" \
        || fail "VoiceInk could not remove the obsolete filesystem recovery snapshot."
fi
/bin/rm -f "$manifest_path"
printf 'Installed VoiceInk candidate %s and preserved the previous bundle at %s\n' \
    "$approved_sha" "$backup_bundle"
