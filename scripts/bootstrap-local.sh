#!/usr/bin/env bash

set -euo pipefail

readonly expected_fork="dguay/VoiceInk"
readonly expected_upstream="Beingpax/VoiceInk"
readonly upstream_url="https://github.com/Beingpax/VoiceInk.git"
readonly installed_app="${VOICEINK_INSTALLED_APP_PATH:-/Applications/VoiceInk.app}"
readonly minimum_free_gib="${VOICEINK_MIN_FREE_GIB:-15}"

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

github_repository() {
    local remote_url="$1"
    local repository

    remote_url="${remote_url%/}"
    remote_url="${remote_url%.git}"

    case "$remote_url" in
        https://github.com/*) repository="${remote_url#https://github.com/}" ;;
        http://github.com/*) repository="${remote_url#http://github.com/}" ;;
        git://github.com/*) repository="${remote_url#git://github.com/}" ;;
        git@github.com:*) repository="${remote_url#git@github.com:}" ;;
        ssh://git@github.com/*) repository="${remote_url#ssh://git@github.com/}" ;;
        *) return 1 ;;
    esac

    printf '%s\n' "$repository" | tr '[:upper:]' '[:lower:]'
}

validate_github_repository_url() {
    local label="$1"
    local expected_repository="$2"
    local remote_url="$3"
    local actual_repository normalized_expected

    actual_repository="$(github_repository "$remote_url")" \
        || fail "$label is not a supported GitHub SSH or HTTPS URL: $remote_url"
    normalized_expected="$(printf '%s\n' "$expected_repository" | tr '[:upper:]' '[:lower:]')"

    [[ "$actual_repository" == "$normalized_expected" ]] \
        || fail "$label resolves to $actual_repository; expected $normalized_expected."
}

validate_remote() {
    local remote_name="$1"
    local expected_repository="$2"
    local remote_url

    remote_url="$(git -C "$repository_root" remote get-url "$remote_name" 2>/dev/null)" \
        || fail "Git remote '$remote_name' is not configured."
    validate_github_repository_url "Git remote '$remote_name'" "$expected_repository" "$remote_url"
}

check_free_space() {
    local requested_path="$1"
    local label="$2"
    local existing_path="$requested_path"
    local available_kib minimum_kib

    while [[ ! -e "$existing_path" && "$existing_path" != "/" ]]; do
        existing_path="$(dirname "$existing_path")"
    done

    available_kib="$(df -Pk "$existing_path" | awk 'NR == 2 { print $4 }')"
    [[ "$available_kib" =~ ^[0-9]+$ ]] || fail "Could not determine available disk space for $label."
    minimum_kib=$((minimum_free_gib * 1024 * 1024))
    (( available_kib >= minimum_kib )) \
        || fail "At least ${minimum_free_gib} GiB free is required for $label; its volume has $((available_kib / 1024 / 1024)) GiB."
    printf 'Disk space for %s: %s GiB available (%s GiB required).\n' \
        "$label" "$((available_kib / 1024 / 1024))" "$minimum_free_gib"
}

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(git -C "$script_directory/.." rev-parse --show-toplevel 2>/dev/null)" \
    || fail "Bootstrap must run from a VoiceInk Git clone."
repository_root="$(cd "$repository_root" && pwd -P)"

[[ "$minimum_free_gib" =~ ^[0-9]+$ ]] \
    || fail "VOICEINK_MIN_FREE_GIB must be a non-negative integer."

validate_remote origin "$expected_fork"
while IFS= read -r origin_push_url; do
    validate_github_repository_url "origin push URL" "$expected_fork" "$origin_push_url"
done < <(git -C "$repository_root" remote get-url --push --all origin)

if ! git -C "$repository_root" remote get-url upstream >/dev/null 2>&1; then
    git -C "$repository_root" remote add upstream "$upstream_url"
    printf 'Added upstream remote: %s\n' "$upstream_url"
fi
validate_remote upstream "$expected_upstream"

[[ -z "$(git -C "$repository_root" status --porcelain)" ]] \
    || fail "The VoiceInk clone has uncommitted changes. Commit or stash them before bootstrap."

push_check_ref="refs/heads/voiceink-bootstrap-access-check-$(date +%s)-$$"
GIT_TERMINAL_PROMPT=0 git -C "$repository_root" push --dry-run --porcelain \
    origin "HEAD:$push_check_ref" >/dev/null 2>&1 \
    || fail "Git cannot authenticate and push to $expected_fork through origin."

command -v xcodebuild >/dev/null 2>&1 || fail "Xcode is not installed or xcodebuild is unavailable."
xcode-select -p >/dev/null 2>&1 || fail "Xcode Command Line Tools are not selected."
xcrun --find clang >/dev/null 2>&1 || fail "Xcode Command Line Tools are incomplete."
xcodebuild -version >/dev/null 2>&1 || fail "Xcode is not usable from the command line."

installed_parent="$(dirname "$installed_app")"
check_free_space "$repository_root" "the clone and local build"
check_free_space "$HOME" "VoiceInk dependencies and Downloads output"
check_free_space "$installed_parent" "the installed app"

[[ -d "$installed_parent" && -w "$installed_parent" && -x "$installed_parent" ]] \
    || fail "VoiceInk cannot replace $installed_app with the current parent-directory permissions."

if ! command -v codex >/dev/null 2>&1 || ! codex login status >/dev/null 2>&1; then
    printf 'Warning: Codex is not installed or authenticated; continuing.\n' >&2
else
    printf 'Codex authentication: ready.\n'
fi

(
    cd "$repository_root"
    git fetch upstream main
)

fork_commit="$(git -C "$repository_root" rev-parse HEAD)"
upstream_commit="$(git -C "$repository_root" merge-base HEAD refs/remotes/upstream/main)" \
    || fail "The fork does not share history with upstream/main."

git config --global voiceink.repositoryPath "$repository_root"
printf 'Registered clone: %s\n' "$repository_root"
printf 'Fork commit: %s\n' "$fork_commit"
printf 'Contained upstream commit: %s\n' "$upstream_commit"

make -C "$repository_root" local \
    "VOICEINK_FORK_COMMIT=$fork_commit" \
    "VOICEINK_UPSTREAM_COMMIT=$upstream_commit"
