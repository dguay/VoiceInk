#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

write_preparation_result() {
    [[ -n "$result_path" ]] || return 0

    mkdir -p "$(dirname "$result_path")"
    result_temporary="$result_path.tmp.$$"
    /usr/bin/plutil -create xml1 "$result_temporary"
    /usr/bin/plutil -insert outcome -string "$1" "$result_temporary"
    /usr/bin/plutil -insert forkCommit -string "$fork_commit" "$result_temporary"
    /usr/bin/plutil -insert upstreamCommit -string "$upstream_commit" "$result_temporary"
    mv "$result_temporary" "$result_path"
}

repository_path="${VOICEINK_REPOSITORY_PATH:-}"
if [[ -z "$repository_path" ]]; then
    repository_path="$(git config --global --get voiceink.repositoryPath 2>/dev/null || true)"
fi

[[ -n "$repository_path" ]] \
    || fail "No VoiceInk clone is registered. Run 'make bootstrap' from the clone first."
repository_path="$(git -C "$repository_path" rev-parse --show-toplevel 2>/dev/null)" \
    || fail "The registered VoiceInk clone is unavailable. Run 'make bootstrap' again."

[[ -z "$(git -C "$repository_path" status --porcelain)" ]] \
    || fail "The VoiceInk clone has uncommitted changes. Commit or stash them before preparing an update."

manifest_path="${VOICEINK_UPDATE_MANIFEST_PATH:-$HOME/Library/Application Support/com.prakashjoshipax.VoiceInk/Updater/staged-candidate.plist}"
result_path="${VOICEINK_UPDATE_RESULT_PATH:-}"
stage_root="$(dirname "$manifest_path")"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/voiceink-update.XXXXXX")"
candidate_worktree="$work_root/candidate"
derived_data="$work_root/DerivedData"
worktree_added=false

cleanup() {
    if [[ "$worktree_added" == true ]]; then
        git -C "$repository_path" worktree remove --force "$candidate_worktree" >/dev/null 2>&1 || true
    fi
    rm -rf "$work_root"
}
trap cleanup EXIT

git -C "$repository_path" fetch origin main
git -C "$repository_path" fetch upstream main

fork_commit="$(git -C "$repository_path" rev-parse refs/remotes/origin/main)" \
    || fail "The fetched fork does not have origin/main."
upstream_commit="$(git -C "$repository_path" rev-parse refs/remotes/upstream/main)" \
    || fail "The fetched upstream does not have upstream/main."
git -C "$repository_path" merge-base --is-ancestor "$upstream_commit" "$fork_commit" \
    || fail "The fetched fork does not contain upstream/main."

if [[ -n "${VOICEINK_INSTALLED_FORK_COMMIT:-}" \
    && "$VOICEINK_INSTALLED_FORK_COMMIT" == "$fork_commit" ]]
then
    rm -f "$manifest_path"
    write_preparation_result upToDate
    exit 0
fi

recovery_state="${VOICEINK_UPDATE_RECOVERY_STATE_PATH:-$HOME/Library/Application Support/com.prakashjoshipax.VoiceInk.UpdaterRecovery/recovery.plist}"
if [[ -f "$recovery_state" ]]; then
    suppressed_fork_commit="$(/usr/bin/plutil -extract suppressedForkCommit raw "$recovery_state" 2>/dev/null || true)"
    if [[ -n "$suppressed_fork_commit" ]]; then
        if [[ "$suppressed_fork_commit" == "$fork_commit" \
            && "${VOICEINK_UPDATE_RETRY_SUPPRESSED_CANDIDATE:-0}" != 1 \
            && "${VOICEINK_UPDATE_CLEAR_SUPPRESSION:-0}" != 1 ]]
        then
            fail "Candidate $fork_commit is suppressed on this Mac after rollback. Retry it explicitly or wait for the fork to change."
        fi
        /usr/bin/plutil -remove suppressedForkCommit "$recovery_state" \
            || fail "VoiceInk could not clear the obsolete candidate suppression."
    fi
fi

git -C "$repository_path" worktree add --detach "$candidate_worktree" "$fork_commit"
worktree_added=true

signing_identity="${LOCAL_CODESIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(git config --global --get voiceink.localCodesignIdentity 2>/dev/null || true)"
fi
signing_identity="${signing_identity:--}"
if [[ "$signing_identity" == "-" ]]; then
    signing_required=NO
else
    signing_required=YES
fi

xcode_arguments=(
    -project VoiceInk.xcodeproj
    -scheme VoiceInk
    -configuration Debug
    -derivedDataPath "$derived_data"
    -xcconfig LocalBuild.xcconfig
    -skipPackagePluginValidation
    -skipMacroValidation
    "VOICEINK_LOCAL_CODESIGN_IDENTITY=$signing_identity"
    "CODE_SIGNING_REQUIRED=$signing_required"
    CODE_SIGNING_ALLOWED=YES
    DEVELOPMENT_TEAM=
    "CODE_SIGN_ENTITLEMENTS=$candidate_worktree/VoiceInk/VoiceInk.local.entitlements"
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_BUILD'
    "VOICEINK_FORK_COMMIT=$fork_commit"
    "VOICEINK_UPSTREAM_COMMIT=$upstream_commit"
    VOICEINK_UPDATER_KIND=fork
)

(
    cd "$candidate_worktree"
    xcodebuild "${xcode_arguments[@]}" \
        -only-testing:VoiceInkTests/UpdaterViewModelTests \
        test
    xcodebuild "${xcode_arguments[@]}" \
        -only-testing:VoiceInkTests \
        test
    xcodebuild "${xcode_arguments[@]}" build
)

candidate_bundle="$derived_data/Build/Products/Debug/VoiceInk.app"
[[ -d "$candidate_bundle" ]] || fail "The local build did not produce VoiceInk.app."
codesign --verify --deep --strict "$candidate_bundle" \
    || fail "The candidate bundle failed signature validation."

info_plist="$candidate_bundle/Contents/Info.plist"
[[ "$(/usr/bin/plutil -extract VoiceInkForkCommit raw "$info_plist")" == "$fork_commit" ]] \
    || fail "The candidate bundle has the wrong fork provenance."
[[ "$(/usr/bin/plutil -extract VoiceInkUpstreamCommit raw "$info_plist")" == "$upstream_commit" ]] \
    || fail "The candidate bundle has the wrong upstream provenance."
[[ "$(/usr/bin/plutil -extract VoiceInkUpdaterKind raw "$info_plist")" == "fork" ]] \
    || fail "The candidate bundle does not contain the local fork updater."

umask 077
candidate_stage="$stage_root/candidates/$fork_commit-$(date +%s)-$$"
staged_bundle="$candidate_stage/VoiceInk.app"
mkdir -p "$candidate_stage"
/usr/bin/ditto "$candidate_bundle" "$staged_bundle"
codesign --verify --deep --strict "$staged_bundle" \
    || fail "The staged candidate bundle failed signature validation."

mkdir -p "$stage_root"
manifest_temporary="$manifest_path.tmp.$$"
/usr/bin/plutil -create xml1 "$manifest_temporary"
/usr/bin/plutil -insert forkCommit -string "$fork_commit" "$manifest_temporary"
/usr/bin/plutil -insert upstreamCommit -string "$upstream_commit" "$manifest_temporary"
/usr/bin/plutil -insert bundlePath -string "$staged_bundle" "$manifest_temporary"
/usr/bin/plutil -insert preparedAt -date "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$manifest_temporary"
mv "$manifest_temporary" "$manifest_path"
write_preparation_result candidatePrepared

printf 'Staged VoiceInk candidate %s at %s\n' "$fork_commit" "$staged_bundle"
