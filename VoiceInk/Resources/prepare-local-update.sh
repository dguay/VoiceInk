#!/usr/bin/env bash

set -Eeuo pipefail

current_stage="preflight"
failure_kind=""
candidate_identifier=""
fork_commit=""
upstream_commit=""
repository_path=""
origin_repository=""
upstream_repository=""
conflict_paths=()
manifest_path="${VOICEINK_UPDATE_MANIFEST_PATH:-$HOME/Library/Application Support/com.prakashjoshipax.VoiceInk/Updater/staged-candidate.plist}"
result_path="${VOICEINK_UPDATE_RESULT_PATH:-}"
progress_path="${VOICEINK_UPDATE_PROGRESS_PATH:-}"
stage_root="$(dirname "$manifest_path")"
failure_state_path="${VOICEINK_UPDATE_FAILURE_STATE_PATH:-$stage_root/failure-state.plist}"
failure_written=false
publication_pending_retry=false
# Persistent build state lives with the updater so consecutive preparations
# reuse resolved packages and compiled dependencies. The worktree path is stable
# so the derived data stays valid, but the worktree itself never outlives a run.
cache_root="$stage_root/BuildCache"
candidate_worktree="$cache_root/Worktree"
derived_data_root="$cache_root/DerivedData"
candidate_retention_seconds="${VOICEINK_UPDATE_CANDIDATE_RETENTION_SECONDS:-1209600}"

# Preparation runs unattended. Git must fail instead of waiting for a terminal,
# askpass dialog, or SSH passphrase prompt that nobody will answer.
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/usr/bin/false
export SSH_ASKPASS=/usr/bin/false
export SSH_ASKPASS_REQUIRE=never
export GCM_INTERACTIVE=never
exec < /dev/null

# The app's watchdog and Cancel terminate the whole process group. Exit through
# the EXIT trap so the worktree and temporary files are still removed.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    local message="$*"
    if [[ "$publication_pending_retry" == true ]]; then
        message="VoiceInk installed the update; publication to the fork is pending: $message"
    fi
    write_failure_result "$message"
    printf 'Error: %s\n' "$message" >&2
    exit 1
}

write_preparation_result() {
    if [[ -n "$result_path" ]]; then
        mkdir -p "$(dirname "$result_path")"
        result_temporary="$result_path.tmp.$$"
        /usr/bin/plutil -create xml1 "$result_temporary"
        /usr/bin/plutil -insert outcome -string "$1" "$result_temporary"
        if [[ -n "$fork_commit" ]]; then
            /usr/bin/plutil -insert forkCommit -string "$fork_commit" "$result_temporary"
        fi
        if [[ -n "$upstream_commit" ]]; then
            /usr/bin/plutil -insert upstreamCommit -string "$upstream_commit" "$result_temporary"
        fi
        if [[ -n "$candidate_identifier" ]]; then
            /usr/bin/plutil -insert candidateIdentifier -string "$candidate_identifier" "$result_temporary"
        fi
        mv "$result_temporary" "$result_path"
    fi
    if [[ "$1" == "upToDate" || "$1" == "candidatePrepared" ]]; then
        rm -f "$failure_state_path"
    fi
}

write_failure_result() {
    local message="$1"
    local failure_temporary
    [[ -n "$result_path" ]] || return 0
    failure_written=true

    mkdir -p "$(dirname "$result_path")"
    failure_temporary="$result_path.tmp.$$"
    /usr/bin/plutil -create xml1 "$failure_temporary"
    /usr/bin/plutil -insert outcome -string failure "$failure_temporary"
    /usr/bin/plutil -insert stage -string "$current_stage" "$failure_temporary"
    if [[ -n "$failure_kind" ]]; then
        /usr/bin/plutil -insert kind -string "$failure_kind" "$failure_temporary"
    fi
    /usr/bin/plutil -insert message -string "$message" "$failure_temporary"
    if [[ -n "$candidate_identifier" ]]; then
        /usr/bin/plutil -insert candidateIdentifier -string "$candidate_identifier" "$failure_temporary"
    fi
    if [[ -n "$fork_commit" ]]; then
        /usr/bin/plutil -insert forkCommit -string "$fork_commit" "$failure_temporary"
    fi
    if [[ -n "$upstream_commit" ]]; then
        /usr/bin/plutil -insert upstreamCommit -string "$upstream_commit" "$failure_temporary"
    fi
    if [[ -n "$repository_path" ]]; then
        /usr/bin/plutil -insert repositoryPath -string "$repository_path" "$failure_temporary"
    fi
    if [[ -n "$origin_repository" ]]; then
        /usr/bin/plutil -insert originRepository -string "$origin_repository" "$failure_temporary"
    fi
    if [[ -n "$upstream_repository" ]]; then
        /usr/bin/plutil -insert upstreamRepository -string "$upstream_repository" "$failure_temporary"
    fi
    /usr/bin/plutil -insert conflicts -array "$failure_temporary"
    local conflict_index=0
    local conflict_path
    if (( ${#conflict_paths[@]} > 0 )); then
        for conflict_path in "${conflict_paths[@]}"; do
            /usr/bin/plutil -insert "conflicts.$conflict_index" -string "$conflict_path" "$failure_temporary"
            conflict_index=$((conflict_index + 1))
        done
    fi
    mv "$failure_temporary" "$result_path"

}

record_unhandled_failure() {
    local status="$?"
    if [[ "$status" -ne 0 && "$failure_written" == false ]]; then
        write_failure_result "VoiceInk update stage '$current_stage' failed."
    fi
    return "$status"
}

trap record_unhandled_failure ERR

record_stage_success() {
    [[ -n "$progress_path" ]] || return 0
    printf '%s\n' "$1" >> "$progress_path"
}

write_suppressed_result() {
    [[ -n "$result_path" ]] || return 0
    mkdir -p "$(dirname "$result_path")"
    cp "$failure_state_path" "$result_path.tmp.$$"
    /usr/bin/plutil -replace outcome -string failureSuppressed "$result_path.tmp.$$" 2>/dev/null \
        || /usr/bin/plutil -insert outcome -string failureSuppressed "$result_path.tmp.$$"
    mv "$result_path.tmp.$$" "$result_path"
}

exit_if_stage_failure_is_unchanged() {
    [[ -n "$candidate_identifier" ]] || return 0
    [[ "${VOICEINK_UPDATE_RETRY_SUPPRESSED_CANDIDATE:-0}" != 1 ]] || return 0
    [[ -f "$failure_state_path" ]] || return 0

    local failed_candidate
    local failed_kind
    local failed_stage
    failed_candidate="$(/usr/bin/plutil -extract candidateIdentifier raw "$failure_state_path" 2>/dev/null || true)"
    failed_kind="$(/usr/bin/plutil -extract kind raw "$failure_state_path" 2>/dev/null || true)"
    failed_stage="$(/usr/bin/plutil -extract stage raw "$failure_state_path" 2>/dev/null || true)"
    [[ "$failed_kind" == "deterministic" \
        && "$failed_candidate" == "$candidate_identifier" \
        && "$failed_stage" == "$current_stage" ]] \
        || return 0

    write_suppressed_result
    exit 0
}

begin_stage() {
    current_stage="$1"
    failure_kind="${2:-}"
    exit_if_stage_failure_is_unchanged
}

# A retained manifest for the installed commit means an earlier post-health
# publication is still pending. Report every failure until it is published as
# a publication failure, so the installed-and-pending state stays visible.
if [[ -n "${VOICEINK_INSTALLED_FORK_COMMIT:-}" && -f "$manifest_path" \
    && "$(/usr/bin/plutil -extract forkCommit raw "$manifest_path" 2>/dev/null || true)" == "$VOICEINK_INSTALLED_FORK_COMMIT" \
    && -n "$(/usr/bin/plutil -extract forkBaseCommit raw "$manifest_path" 2>/dev/null || true)" ]]
then
    publication_pending_retry=true
    begin_stage publication transient
fi

repository_path="${VOICEINK_REPOSITORY_PATH:-}"
if [[ -z "$repository_path" ]]; then
    repository_path="$(git config --global --get voiceink.repositoryPath 2>/dev/null || true)"
fi

[[ -n "$repository_path" ]] \
    || fail "No VoiceInk clone is registered. Run 'make bootstrap' from the clone first."
repository_path="$(git -C "$repository_path" rev-parse --show-toplevel 2>/dev/null)" \
    || fail "The registered VoiceInk clone is unavailable. Run 'make bootstrap' again."
origin_repository="$(git -C "$repository_path" remote get-url origin 2>/dev/null)" \
    || fail "The registered VoiceInk clone does not have an origin remote."
upstream_repository="$(git -C "$repository_path" remote get-url upstream 2>/dev/null)" \
    || fail "The registered VoiceInk clone does not have an upstream remote."
# Keep any SSH command the clone or user configured, but never let it prompt.
ssh_command="${GIT_SSH_COMMAND:-$(git -C "$repository_path" config --get core.sshCommand 2>/dev/null || true)}"
export GIT_SSH_COMMAND="${ssh_command:-ssh} -o BatchMode=yes"
fork_commit="$(git -C "$repository_path" rev-parse refs/remotes/origin/main 2>/dev/null || true)"
upstream_commit="$(git -C "$repository_path" rev-parse refs/remotes/upstream/main 2>/dev/null || true)"

[[ -z "$(git -C "$repository_path" status --porcelain)" ]] \
    || fail "The VoiceInk clone has uncommitted changes. Commit or stash them before preparing an update."

work_root="$(mktemp -d "${TMPDIR:-/tmp}/voiceink-update.XXXXXX")"
worktree_added=false
candidate_ref=""
candidate_stage=""
candidate_staged=false
caffeinate_pid=""

# Keep the Mac from idle-sleeping in the middle of a long build. The assertion
# ends with this helper even when it is killed.
if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -i -w "$$" >/dev/null 2>&1 &
    caffeinate_pid=$!
fi

cleanup_candidate_artifacts() {
    local cleanup_sha="$1"
    local cleanup_ref="$2"
    local cleanup_bundle="$3"
    local cleanup_stage
    local cleanup_stage_name

    [[ "$cleanup_sha" =~ ^[0-9a-f]{40}$ ]] || return 0

    cleanup_stage="$(dirname "$cleanup_bundle")"
    cleanup_stage_name="$(basename "$cleanup_stage")"
    if [[ "$(dirname "$cleanup_stage")" == "$stage_root/candidates" \
        && "$(basename "$cleanup_bundle")" == "VoiceInk.app" \
        && "$cleanup_stage_name" =~ ^$cleanup_sha-[0-9]+-[0-9]+$ ]]
    then
        rm -rf "$cleanup_stage"
    fi

    if [[ "$cleanup_ref" == "refs/voiceink-updater/candidates/$cleanup_sha" \
        || "$cleanup_ref" =~ ^refs/voiceink-updater/candidates/$cleanup_sha-[0-9]+-[0-9]+$ ]]
    then
        git -C "$repository_path" update-ref -d "$cleanup_ref" "$cleanup_sha"
    fi
}

# A checkout interrupted by a kill keeps Git's "initializing" lock, which makes
# prune keep the registration and blocks the next worktree add; this stable
# path is owned by the updater, so release that lock before removing it.
unlock_candidate_worktree() {
    git -C "$repository_path" worktree unlock "$candidate_worktree" >/dev/null 2>&1 || true
}

remove_candidate_worktree() {
    unlock_candidate_worktree
    git -C "$repository_path" worktree remove --force "$candidate_worktree" >/dev/null 2>&1 \
        || rm -rf "$candidate_worktree"
    git -C "$repository_path" worktree prune >/dev/null 2>&1 || true
}

# A preparation that was killed outright can leave the stable worktree behind.
# Replace it rather than build from whatever state it was left in.
add_candidate_worktree() {
    if [[ -e "$candidate_worktree" ]]; then
        remove_candidate_worktree
    fi
    unlock_candidate_worktree
    git -C "$repository_path" worktree prune >/dev/null 2>&1 || true
    mkdir -p "$cache_root"
    git -C "$repository_path" worktree add --detach "$candidate_worktree" "$1"
    worktree_added=true
}

# Removes candidate references and stage directories that the manifest does not
# name, that are older than the retention window, and that the fork's main does
# not contain. The manifest names the staged candidate and a candidate retained
# for publication, so neither is ever pruned.
candidate_is_expired_orphan() {
    local name="$1"
    local cutoff="$2"
    [[ "$name" =~ ^([0-9a-f]{40})-([0-9]+)-[0-9]+$ ]] || return 1
    local sha="${BASH_REMATCH[1]}"
    local created_at="${BASH_REMATCH[2]}"
    (( created_at < cutoff )) || return 1
    if git -C "$repository_path" merge-base --is-ancestor "$sha" "$fork_base_commit" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

prune_orphaned_candidates() {
    local protected_ref=""
    local protected_stage=""
    local protected_bundle=""
    local cutoff
    local reference
    local stage
    if [[ -f "$manifest_path" ]]; then
        protected_ref="$(/usr/bin/plutil -extract candidateRef raw "$manifest_path" 2>/dev/null || true)"
        protected_bundle="$(/usr/bin/plutil -extract bundlePath raw "$manifest_path" 2>/dev/null || true)"
        [[ -z "$protected_bundle" ]] || protected_stage="$(dirname "$protected_bundle")"
    fi
    cutoff=$(( $(date +%s) - candidate_retention_seconds ))

    while IFS= read -r reference; do
        [[ -n "$reference" && "$reference" != "$protected_ref" ]] || continue
        if candidate_is_expired_orphan "${reference#refs/voiceink-updater/candidates/}" "$cutoff"; then
            git -C "$repository_path" update-ref -d "$reference" >/dev/null 2>&1 || true
        fi
    done < <(git -C "$repository_path" for-each-ref --format='%(refname)' refs/voiceink-updater/candidates/)

    for stage in "$stage_root/candidates"/*; do
        [[ -d "$stage" && "$stage" != "$protected_stage" ]] || continue
        if candidate_is_expired_orphan "$(basename "$stage")" "$cutoff"; then
            rm -rf "$stage"
        fi
    done
}

cleanup() {
    if [[ "$worktree_added" == true ]]; then
        remove_candidate_worktree
    fi
    if [[ -n "$caffeinate_pid" ]]; then
        kill "$caffeinate_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$candidate_ref" && "$candidate_staged" == false ]]; then
        git -C "$repository_path" update-ref -d "$candidate_ref" >/dev/null 2>&1 || true
    fi
    if [[ -n "$candidate_stage" && "$candidate_staged" == false ]]; then
        rm -rf "$candidate_stage"
    fi
    rm -rf "$work_root"
}
trap cleanup EXIT

# The installed app already is this verified candidate, but an earlier
# post-health publication or local-main convergence did not finish. Publish it
# and converge local main without rebuilding. Artifacts stay until both finish.
publish_retained_candidate() {
    local retained_ref
    local retained_bundle
    local local_main_sha

    begin_stage publication transient
    retained_ref="$(/usr/bin/plutil -extract candidateRef raw "$manifest_path" 2>/dev/null || true)"
    retained_bundle="$(/usr/bin/plutil -extract bundlePath raw "$manifest_path" 2>/dev/null || true)"
    local_main_sha="$(git -C "$repository_path" rev-parse --verify --quiet refs/heads/main)" \
        || fail "The VoiceInk clone does not have a local main branch."
    git -C "$repository_path" merge-base --is-ancestor "$local_main_sha" "$fork_commit" \
        || fail "Local main cannot fast-forward to the installed update. Reconcile local main, then check for updates again."
    if [[ "$fork_base_commit" != "$fork_commit" ]]; then
        [[ -n "$retained_ref" \
            && "$(git -C "$repository_path" rev-parse --verify --quiet "$retained_ref" 2>/dev/null || true)" == "$fork_commit" ]] \
            || fail "The installed update's preparation reference is missing, so VoiceInk cannot publish it."
        git -C "$repository_path" push origin "$fork_commit:refs/heads/main" \
            || fail "VoiceInk could not publish the installed update to origin. It will retry on the next update check."
    fi
    if [[ "$local_main_sha" != "$fork_commit" ]]; then
        if [[ "$(git -C "$repository_path" symbolic-ref --quiet --short HEAD || true)" == "main" ]]; then
            git -C "$repository_path" merge --ff-only "$fork_commit" >/dev/null \
                || fail "VoiceInk published the installed update, but could not fast-forward local main."
        else
            git -C "$repository_path" update-ref refs/heads/main "$fork_commit" "$local_main_sha" \
                || fail "VoiceInk published the installed update, but could not fast-forward local main."
        fi
    fi
    cleanup_candidate_artifacts "$fork_commit" "$retained_ref" "$retained_bundle"
    rm -f "$manifest_path"
    record_stage_success publication
}

[[ "$publication_pending_retry" == true ]] || begin_stage fetch
git -C "$repository_path" fetch origin main \
    || fail "VoiceInk could not fetch origin/main."
fork_commit="$(git -C "$repository_path" rev-parse refs/remotes/origin/main)" \
    || fail "The fetched fork does not have origin/main."
git -C "$repository_path" fetch upstream main \
    || fail "VoiceInk could not fetch upstream/main."
upstream_commit="$(git -C "$repository_path" rev-parse refs/remotes/upstream/main)" \
    || fail "The fetched upstream does not have upstream/main."
fork_base_commit="$fork_commit"
candidate_identifier="$fork_base_commit:$upstream_commit"
record_stage_success fetch
if [[ -f "$failure_state_path" ]]; then
    failed_candidate="$(/usr/bin/plutil -extract candidateIdentifier raw "$failure_state_path" 2>/dev/null || true)"
    if [[ "$failed_candidate" != "$candidate_identifier" ]]; then
        rm -f "$failure_state_path"
    fi
fi
prune_orphaned_candidates || true

# Identify a retained installed candidate before recomputing the merge: a
# recomputed merge commit has a new SHA, so only the retained manifest names
# the installed candidate. Origin must still be the candidate's base, or
# already be the candidate when only local-main convergence is left.
if [[ -n "${VOICEINK_INSTALLED_FORK_COMMIT:-}" && -f "$manifest_path" ]]; then
    retained_fork_commit="$(/usr/bin/plutil -extract forkCommit raw "$manifest_path" 2>/dev/null || true)"
    retained_base_commit="$(/usr/bin/plutil -extract forkBaseCommit raw "$manifest_path" 2>/dev/null || true)"
    retained_upstream_commit="$(/usr/bin/plutil -extract upstreamCommit raw "$manifest_path" 2>/dev/null || true)"
    if [[ "$retained_fork_commit" == "$VOICEINK_INSTALLED_FORK_COMMIT" \
        && -n "$retained_base_commit" \
        && ( "$fork_base_commit" == "$retained_base_commit" \
            || "$fork_base_commit" == "$retained_fork_commit" ) ]]
    then
        fork_commit="$retained_fork_commit"
        upstream_commit="${retained_upstream_commit:-$upstream_commit}"
        publish_retained_candidate
        write_preparation_result upToDate
        printf 'Published retained VoiceInk candidate %s.\n' "$fork_commit"
        exit 0
    fi
fi
# Origin moved past the retained candidate's base, so it is no longer a
# pending publication; later stages report their own failures.
publication_pending_retry=false

fork_commit="$fork_base_commit"
begin_stage merge
if ! git -C "$repository_path" merge-base --is-ancestor "$upstream_commit" "$fork_base_commit"; then
    add_candidate_worktree "$fork_base_commit"
    if git -C "$repository_path" merge-base --is-ancestor "$fork_base_commit" "$upstream_commit"; then
        git -C "$candidate_worktree" merge --ff-only "$upstream_commit"
    else
        if ! git -C "$candidate_worktree" \
            -c user.name="VoiceInk Updater" \
            -c user.email="voiceink-updater@localhost" \
            merge --no-ff --no-gpg-sign \
            -m "chore(updater): merge upstream main" "$upstream_commit" \
            >/dev/null 2>&1
        then
            while IFS= read -r conflict_path; do
                [[ -n "$conflict_path" ]] && conflict_paths+=("$conflict_path")
            done < <(git -C "$candidate_worktree" diff --name-only --diff-filter=U)
            fail "The fetched fork conflicts with upstream/main. Resolve the shared fork before retrying."
        fi
    fi
    fork_commit="$(git -C "$candidate_worktree" rev-parse HEAD)"
fi

if [[ -n "${VOICEINK_INSTALLED_FORK_COMMIT:-}" \
    && "$VOICEINK_INSTALLED_FORK_COMMIT" != "$fork_commit" ]] \
    && ! git -C "$repository_path" merge-base --is-ancestor \
        "$VOICEINK_INSTALLED_FORK_COMMIT" "$fork_base_commit"
then
    fail "The fetched fork does not descend from the installed VoiceInk revision. Automatic downgrade or history replacement is blocked."
fi
record_stage_success merge

if [[ -n "${VOICEINK_INSTALLED_FORK_COMMIT:-}" \
    && "$VOICEINK_INSTALLED_FORK_COMMIT" == "$fork_commit" ]]
then
    if [[ -f "$manifest_path" ]]; then
        cleanup_candidate_artifacts \
            "$(/usr/bin/plutil -extract forkCommit raw "$manifest_path" 2>/dev/null || true)" \
            "$(/usr/bin/plutil -extract candidateRef raw "$manifest_path" 2>/dev/null || true)" \
            "$(/usr/bin/plutil -extract bundlePath raw "$manifest_path" 2>/dev/null || true)"
    fi
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

if [[ "${VOICEINK_UPDATE_DEFER_BUILD:-0}" == 1 ]]; then
    write_preparation_result buildDeferred
    exit 0
fi

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

describe_signing_identity() {
    if [[ "$1" == "-" ]]; then
        printf 'an ad-hoc signature (-)'
    else
        printf "'%s'" "$1"
    fi
}

# Resolves the configured selector (a certificate SHA-1 or a name) to exactly
# one valid signing certificate in the keychain, so preflight compares and
# xcodebuild signs with the same certificate. A name can match a replacement
# certificate that only shares it, so the comparison is always by fingerprint.
signing_fingerprint=""
signing_name=""
resolve_signing_identity() {
    local listing
    local line
    local hash
    local name
    local selector_hash=""
    local matched_hashes=()
    local matched_names=()
    local descriptions=""
    local index
    local previous_stage="$current_stage"
    local previous_kind="$failure_kind"

    [[ "$signing_identity" != "-" ]] || return 0
    if [[ "$signing_identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        selector_hash="$(printf '%s' "$signing_identity" | tr '[:lower:]' '[:upper:]')"
    fi
    listing="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+\"(.*)\"[[:space:]]*$ ]] \
            || continue
        hash="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')"
        name="${BASH_REMATCH[2]}"
        if [[ -n "$selector_hash" ]]; then
            [[ "$hash" == "$selector_hash" ]] || continue
        else
            [[ "$name" == *"$signing_identity"* ]] || continue
        fi
        if (( ${#matched_hashes[@]} > 0 )); then
            for index in "${!matched_hashes[@]}"; do
                [[ "${matched_hashes[$index]}" != "$hash" ]] || continue 2
            done
        fi
        matched_hashes+=("$hash")
        matched_names+=("$name")
    done < <(printf '%s\n' "$listing")

    current_stage=preflight
    failure_kind=deterministic
    if (( ${#matched_hashes[@]} == 0 )); then
        fail "No valid code signing identity matching $(describe_signing_identity "$signing_identity") is in the keychain, so the update stopped before building. Set the persisted identity to an available certificate's SHA-1 with: git config --global voiceink.localCodesignIdentity <SHA-1>"
    fi
    if (( ${#matched_hashes[@]} > 1 )); then
        for index in "${!matched_hashes[@]}"; do
            descriptions="$descriptions${descriptions:+, }'${matched_names[$index]}' (${matched_hashes[$index]})"
        done
        fail "The signing identity setting $(describe_signing_identity "$signing_identity") matches ${#matched_hashes[@]} certificates: $descriptions. The update stopped before building. Choose one by SHA-1 with: git config --global voiceink.localCodesignIdentity <SHA-1>"
    fi
    current_stage="$previous_stage"
    failure_kind="$previous_kind"
    signing_fingerprint="${matched_hashes[0]}"
    signing_name="${matched_names[0]}"
}

# macOS ties VoiceInk's privacy access to its signing identity. A candidate
# signed by another identity (for example ad-hoc because the persisted identity
# setting is missing, or a different certificate with the same name) would lose
# that access and be rolled back after install, so stop before spending a build
# on it. An unreadable installed signature leaves nothing to compare, and the
# post-install permission check still runs.
verify_signing_identity() {
    local installed_bundle="${VOICEINK_INSTALLED_BUNDLE_PATH:-}"
    local details
    local line
    local installed_name=""
    local installed_hash=""
    local certificate_prefix="$work_root/installed-certificate"
    local matches=false
    local installed_description
    local candidate_description
    local suggested_identity

    [[ -n "$installed_bundle" && -d "$installed_bundle" ]] || return 0
    details="$(codesign -d --verbose=2 "$installed_bundle" 2>&1)" || return 0
    while IFS= read -r line; do
        if [[ "$line" == "Signature=adhoc" ]]; then
            installed_name="-"
            break
        fi
        if [[ "$line" == Authority=* ]]; then
            installed_name="${line#Authority=}"
            break
        fi
    done < <(printf '%s\n' "$details")
    [[ -n "$installed_name" ]] || return 0
    if [[ "$installed_name" != "-" ]] \
        && codesign -d --extract-certificates="$certificate_prefix" "$installed_bundle" >/dev/null 2>&1 \
        && [[ -f "${certificate_prefix}0" ]]
    then
        installed_hash="$(shasum -a 1 "${certificate_prefix}0" | awk '{ print toupper($1) }')"
    fi

    if [[ "$signing_identity" == "-" ]]; then
        if [[ "$installed_name" == "-" ]]; then
            matches=true
        fi
    else
        [[ -n "$installed_hash" || "$installed_name" == "-" ]] || return 0
        if [[ "$installed_hash" == "$signing_fingerprint" ]]; then
            matches=true
        fi
    fi
    [[ "$matches" == false ]] || return 0

    installed_description="$(describe_signing_identity "$installed_name")"
    if [[ -n "$installed_hash" ]]; then
        installed_description="$installed_description ($installed_hash)"
    fi
    if [[ "$signing_identity" == "-" ]]; then
        candidate_description="$(describe_signing_identity "-")"
    else
        candidate_description="$(describe_signing_identity "$signing_name") ($signing_fingerprint)"
    fi
    suggested_identity="${installed_hash:-$installed_name}"
    if [[ "$suggested_identity" == *" "* ]]; then
        suggested_identity="\"$suggested_identity\""
    fi
    current_stage=preflight
    failure_kind=deterministic
    fail "VoiceInk would sign this update with $candidate_description, but the installed VoiceInk is signed with $installed_description. macOS would treat the update as a different app and drop VoiceInk's privacy access, so the update stopped before building. Set the persisted identity with: git config --global voiceink.localCodesignIdentity $suggested_identity"
}

resolve_signing_identity
verify_signing_identity

if [[ "$worktree_added" == false ]]; then
    add_candidate_worktree "$fork_commit"
fi

xcode_arguments=(
    -project VoiceInk.xcodeproj
    -scheme VoiceInk
    -configuration Release
    -clonedSourcePackagesDirPath "$cache_root/SourcePackages"
    -packageCachePath "$cache_root/PackageCache"
    -xcconfig LocalBuild.xcconfig
    -skipPackagePluginValidation
    -skipMacroValidation
    "VOICEINK_LOCAL_CODESIGN_IDENTITY=${signing_fingerprint:-$signing_identity}"
    "CODE_SIGNING_REQUIRED=$signing_required"
    CODE_SIGNING_ALLOWED=YES
    DEVELOPMENT_TEAM=
    "CODE_SIGN_ENTITLEMENTS=$candidate_worktree/VoiceInk/VoiceInk.local.entitlements"
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_BUILD'
    "VOICEINK_FORK_COMMIT=$fork_commit"
    "VOICEINK_UPSTREAM_COMMIT=$upstream_commit"
    VOICEINK_UPDATER_KIND=fork
)

# The unit suite contains the updater tests, so it runs once. Its testable build
# embeds the test bundle and cannot be installed, so the release build keeps its
# own persistent derived data; each pass stays incremental across preparations.
begin_stage test
(
    cd "$candidate_worktree"
    xcodebuild "${xcode_arguments[@]}" \
        -derivedDataPath "$derived_data_root/Test" \
        ENABLE_TESTABILITY=YES \
        -only-testing:VoiceInkTests \
        test
) || fail "VoiceInk unit tests failed for this candidate."
record_stage_success test
begin_stage build
(
    cd "$candidate_worktree"
    xcodebuild "${xcode_arguments[@]}" \
        -derivedDataPath "$derived_data_root/Release" \
        build
) || fail "VoiceInk could not build this candidate."
record_stage_success build

begin_stage staging
candidate_bundle="$derived_data_root/Release/Build/Products/Release/VoiceInk.app"
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

# Describe the candidate for the Update Ready UI: upstream commits the installed
# app does not contain yet (or that the fork base lacks when the installed
# revision is unknown), with a bounded list of their newest subjects. The
# summary is informational, so a git failure omits it instead of failing.
write_change_summary() {
    local summary_manifest="$1"
    local summary_base="$fork_base_commit"
    local subject_limit="${VOICEINK_UPDATE_SUMMARY_SUBJECT_LIMIT:-20}"
    local commit_count
    local subject
    local subject_index=0

    [[ "$subject_limit" =~ ^[0-9]+$ ]] || subject_limit=20
    if [[ -n "${VOICEINK_INSTALLED_FORK_COMMIT:-}" ]] \
        && git -C "$repository_path" cat-file -e "$VOICEINK_INSTALLED_FORK_COMMIT^{commit}" 2>/dev/null
    then
        summary_base="$VOICEINK_INSTALLED_FORK_COMMIT"
    fi
    commit_count="$(git -C "$repository_path" rev-list --count "$summary_base..$upstream_commit" 2>/dev/null)" \
        || return 0
    /usr/bin/plutil -insert changeSummary -dictionary "$summary_manifest"
    /usr/bin/plutil -insert changeSummary.upstreamCommitCount -integer "$commit_count" "$summary_manifest"
    /usr/bin/plutil -insert changeSummary.upstreamCommitSubjects -array "$summary_manifest"
    [[ "$subject_limit" -gt 0 ]] || return 0
    while IFS= read -r subject; do
        /usr/bin/plutil -insert "changeSummary.upstreamCommitSubjects.$subject_index" \
            -string "$subject" "$summary_manifest"
        subject_index=$((subject_index + 1))
    done < <(git -C "$repository_path" log --format=%s \
        --max-count="$subject_limit" "$summary_base..$upstream_commit" 2>/dev/null || true)
}

mkdir -p "$stage_root"
previous_candidate_sha=""
previous_candidate_ref=""
previous_candidate_bundle=""
if [[ -f "$manifest_path" ]]; then
    previous_candidate_sha="$(/usr/bin/plutil -extract forkCommit raw "$manifest_path" 2>/dev/null || true)"
    previous_candidate_ref="$(/usr/bin/plutil -extract candidateRef raw "$manifest_path" 2>/dev/null || true)"
    previous_candidate_bundle="$(/usr/bin/plutil -extract bundlePath raw "$manifest_path" 2>/dev/null || true)"
fi
manifest_temporary="$manifest_path.tmp.$$"
/usr/bin/plutil -create xml1 "$manifest_temporary"
/usr/bin/plutil -insert forkCommit -string "$fork_commit" "$manifest_temporary"
/usr/bin/plutil -insert forkBaseCommit -string "$fork_base_commit" "$manifest_temporary"
/usr/bin/plutil -insert upstreamCommit -string "$upstream_commit" "$manifest_temporary"
/usr/bin/plutil -insert bundlePath -string "$staged_bundle" "$manifest_temporary"
/usr/bin/plutil -insert preparedAt -date "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$manifest_temporary"
write_change_summary "$manifest_temporary"
candidate_ref="refs/voiceink-updater/candidates/$fork_commit-$(date +%s)-$$"
/usr/bin/plutil -insert candidateRef -string "$candidate_ref" "$manifest_temporary"
git -C "$repository_path" update-ref "$candidate_ref" "$fork_commit"
mv "$manifest_temporary" "$manifest_path"
candidate_staged=true
cleanup_candidate_artifacts \
    "$previous_candidate_sha" \
    "$previous_candidate_ref" \
    "$previous_candidate_bundle"
record_stage_success staging
write_preparation_result candidatePrepared

printf 'Staged VoiceInk candidate %s at %s\n' "$fork_commit" "$staged_bundle"
