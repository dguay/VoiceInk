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
candidate_temporary="$target_parent/.VoiceInk.install.$$"
retired_bundle="$target_parent/.VoiceInk.retired.$$"
backup_temporary="$backup_parent/.VoiceInk.backup.$$"
previous_backup="$backup_bundle.replaced.$$"
health_path="${VOICEINK_UPDATE_HEALTH_PATH:-$stage_root/install-health.plist}"
failed_root="$stage_root/failed/$approved_sha-$$"
launcher="${VOICEINK_UPDATE_LAUNCHER:-}"
relauncher="${VOICEINK_UPDATE_RELAUNCHER:-}"
atomic_replacer="${VOICEINK_UPDATE_ATOMIC_REPLACER:-}"
health_timeout="${VOICEINK_UPDATE_HEALTH_TIMEOUT_SECONDS:-30}"
stability_seconds="${VOICEINK_UPDATE_STABILITY_SECONDS:-10}"
parent_exit_timeout="${VOICEINK_UPDATE_PARENT_EXIT_TIMEOUT_SECONDS:-30}"
replacement_started=false
parent_terminated=false
launched_pid=""

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

finish_transaction() {
    result=$?
    trap - EXIT
    set +e

    # Once replacement begins, every failure path must stop the candidate, restore
    # the preserved app, and relaunch that known-good version.
    if [[ "$result" -ne 0 && "$replacement_started" == true ]]; then
        if [[ "$launched_pid" =~ ^[1-9][0-9]*$ ]]; then
            kill -TERM "$launched_pid" >/dev/null 2>&1 || true
        fi
        mkdir -p "$failed_root"
        if [[ -d "$target_bundle" ]]; then
            mv "$target_bundle" "$failed_root/VoiceInk.app" >/dev/null 2>&1 || true
        fi
        if [[ -d "$retired_bundle" ]]; then
            mv "$retired_bundle" "$target_bundle" >/dev/null 2>&1 || true
        elif [[ -d "$backup_bundle" ]]; then
            /usr/bin/ditto "$backup_bundle" "$target_bundle" >/dev/null 2>&1 || true
        fi
        relaunch_previous >/dev/null 2>&1 || true
    elif [[ "$result" -ne 0 && "$parent_terminated" == true ]]; then
        # A failure between termination and replacement leaves the old bundle in
        # place but VoiceInk closed, so recovery still has to relaunch it.
        relaunch_previous >/dev/null 2>&1 || true
    fi

    if [[ -d "$candidate_temporary" ]]; then
        mkdir -p "$failed_root"
        mv "$candidate_temporary" "$failed_root/uninstalled-VoiceInk.app" >/dev/null 2>&1 || true
    fi
    if [[ -d "$backup_temporary" ]]; then
        mkdir -p "$failed_root"
        mv "$backup_temporary" "$failed_root/incomplete-backup.app" >/dev/null 2>&1 || true
    fi
    if [[ -d "$previous_backup" ]]; then
        /bin/rm -rf "$previous_backup"
    fi

    exit "$result"
}
trap finish_transaction EXIT

mkdir -p "$target_parent" "$backup_parent"
/usr/bin/ditto "$staged_bundle" "$candidate_temporary"
codesign --verify --deep --strict "$candidate_temporary" \
    || fail "The installation copy failed signature validation."
/usr/bin/ditto "$target_bundle" "$backup_temporary"
if [[ -d "$backup_bundle" ]]; then
    mv "$backup_bundle" "$previous_backup"
fi
mv "$backup_temporary" "$backup_bundle"

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

replacement_started=true
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
