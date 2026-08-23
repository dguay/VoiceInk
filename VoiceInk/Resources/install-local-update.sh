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
recovery_temporary="$recovery_root.pending.$$"
previous_recovery="$recovery_root.replaced.$$"
health_path="${VOICEINK_UPDATE_HEALTH_PATH:-$stage_root/install-health.plist}"
launcher="${VOICEINK_UPDATE_LAUNCHER:-}"
relauncher="${VOICEINK_UPDATE_RELAUNCHER:-}"
atomic_replacer="${VOICEINK_UPDATE_ATOMIC_REPLACER:-}"
credential_snapshot_committer="${VOICEINK_UPDATE_CREDENTIAL_SNAPSHOT_COMMITTER:-}"
recovery_mover="${VOICEINK_UPDATE_RECOVERY_MOVER:-}"
health_timeout="${VOICEINK_UPDATE_HEALTH_TIMEOUT_SECONDS:-30}"
stability_seconds="${VOICEINK_UPDATE_STABILITY_SECONDS:-10}"
parent_exit_timeout="${VOICEINK_UPDATE_PARENT_EXIT_TIMEOUT_SECONDS:-30}"
parent_terminated=false
launched_pid=""
recovery_published=false
recovery_committed=false

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

commit_credential_snapshot() {
    if [[ -n "$credential_snapshot_committer" ]]; then
        "$credential_snapshot_committer"
        return
    fi
    current_executable="$target_bundle/Contents/MacOS/VoiceInk"
    [[ -x "$current_executable" ]] || fail "The installed VoiceInk executable is missing."
    "$current_executable" --voiceink-commit-update-credentials
}

move_recovery_directory() {
    if [[ -n "$recovery_mover" ]]; then
        "$recovery_mover" "$1" "$2"
    else
        mv "$1" "$2"
    fi
}

finish_transaction() {
    result=$?
    trap - EXIT
    set +e

    # The credential snapshot and recovery directory commit as a pair. If
    # credential promotion fails, restore the prior directory before relaunch.
    if [[ "$result" -ne 0 && "$recovery_committed" == false ]]; then
        if [[ -d "$previous_recovery" ]]; then
            /bin/rm -rf "$recovery_root"
            mv "$previous_recovery" "$recovery_root" || true
        elif [[ "$recovery_published" == true ]]; then
            /bin/rm -rf "$recovery_root"
        fi
    fi

    # Once replacement begins, every failure path must stop the candidate, restore
    # the preserved app, and relaunch that known-good version.
    installed_after_failure="$(/usr/bin/plutil -extract VoiceInkForkCommit raw "$target_bundle/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$result" -ne 0 && "$recovery_committed" == true && "$installed_after_failure" == "$approved_sha" ]]; then
        if [[ "$launched_pid" =~ ^[1-9][0-9]*$ ]]; then
            kill -TERM "$launched_pid" >/dev/null 2>&1 || true
            for ((attempt = 0; attempt < parent_exit_timeout * 10; attempt++)); do
                if ! kill -0 "$launched_pid" 2>/dev/null; then
                    break
                fi
                sleep 0.1
            done
            if kill -0 "$launched_pid" 2>/dev/null; then
                kill -KILL "$launched_pid" >/dev/null 2>&1 || true
            fi
        fi
        if ! /bin/bash "$restoration_script" --automatic "$target_bundle" "$backup_bundle"; then
            printf 'Error: Automatic rollback could not restore a consistent local state.\n' >&2
            result=2
        fi
    elif [[ "$result" -ne 0 && "$parent_terminated" == true ]]; then
        # A failure between termination and replacement leaves the old bundle in
        # place but VoiceInk closed, so recovery still has to relaunch it.
        relaunch_previous >/dev/null 2>&1 || true
    fi

    /bin/rm -rf "$candidate_temporary" "$recovery_temporary" "$retired_bundle"

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
/usr/bin/ditto "$staged_bundle" "$candidate_temporary"
codesign --verify --deep --strict "$candidate_temporary" \
    || fail "The installation copy failed signature validation."

umask 077
mkdir -p "$recovery_temporary"
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

# VoiceInk is now stopped, so these two clones describe one consistent generation.
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

previous_fork_sha="$(/usr/bin/plutil -extract VoiceInkForkCommit raw "$target_bundle/Contents/Info.plist" 2>/dev/null)" \
    || fail "The installed VoiceInk bundle has no fork provenance."
/usr/bin/plutil -create xml1 "$recovery_temporary/recovery.plist"
/usr/bin/plutil -insert previousForkCommit -string "$previous_fork_sha" "$recovery_temporary/recovery.plist"
/usr/bin/plutil -insert candidateForkCommit -string "$approved_sha" "$recovery_temporary/recovery.plist"

# Publish the complete app, state, preferences, and metadata as one recovery
# directory. The prior generation remains available until this rename succeeds.
if [[ -d "$recovery_root" ]]; then
    move_recovery_directory "$recovery_root" "$previous_recovery"
fi
move_recovery_directory "$recovery_temporary" "$recovery_root"
recovery_published=true
commit_credential_snapshot \
    || fail "VoiceInk could not commit the matching credential recovery snapshot."
recovery_committed=true
/bin/rm -rf "$previous_recovery"

replace_bundle_atomically

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

/bin/rm -rf "$retired_bundle"
/bin/rm -f "$manifest_path"
printf 'Installed VoiceInk candidate %s and preserved the previous bundle at %s\n' \
    "$approved_sha" "$backup_bundle"
