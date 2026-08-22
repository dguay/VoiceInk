#!/usr/bin/env bash

set -euo pipefail

readonly expected_fork="${VOICEINK_FORK_REPOSITORY:-dguay/VoiceInk}"
readonly expected_upstream="${VOICEINK_UPSTREAM_REPOSITORY:-Beingpax/VoiceInk}"
readonly upstream_url="${VOICEINK_UPSTREAM_URL:-https://github.com/Beingpax/VoiceInk.git}"
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

validate_remote() {
    local remote_name="$1"
    local expected_repository="$2"
    local remote_url actual_repository normalized_expected

    remote_url="$(git -C "$repository_root" remote get-url "$remote_name" 2>/dev/null)" \
        || fail "Git remote '$remote_name' is not configured."
    actual_repository="$(github_repository "$remote_url")" \
        || fail "Git remote '$remote_name' is not a supported GitHub SSH or HTTPS URL: $remote_url"
    normalized_expected="$(printf '%s\n' "$expected_repository" | tr '[:upper:]' '[:lower:]')"

    [[ "$actual_repository" == "$normalized_expected" ]] \
        || fail "Git remote '$remote_name' resolves to $actual_repository; expected $normalized_expected."
}

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(git -C "$script_directory/.." rev-parse --show-toplevel 2>/dev/null)" \
    || fail "Bootstrap must run from a VoiceInk Git clone."
repository_root="$(cd "$repository_root" && pwd -P)"

[[ "$minimum_free_gib" =~ ^[0-9]+$ ]] \
    || fail "VOICEINK_MIN_FREE_GIB must be a non-negative integer."

validate_remote origin "$expected_fork"

if ! git -C "$repository_root" remote get-url upstream >/dev/null 2>&1; then
    git -C "$repository_root" remote add upstream "$upstream_url"
    printf 'Added upstream remote: %s\n' "$upstream_url"
fi
validate_remote upstream "$expected_upstream"

[[ -z "$(git -C "$repository_root" status --porcelain)" ]] \
    || fail "The VoiceInk clone has uncommitted changes. Commit or stash them before bootstrap."

command -v gh >/dev/null 2>&1 || fail "GitHub CLI is required to verify push access."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run 'gh auth login'."
[[ "$(gh api "repos/$expected_fork" --jq '.permissions.push' 2>/dev/null)" == "true" ]] \
    || fail "The authenticated GitHub account cannot push to $expected_fork."

command -v xcodebuild >/dev/null 2>&1 || fail "Xcode is not installed or xcodebuild is unavailable."
xcode-select -p >/dev/null 2>&1 || fail "Xcode Command Line Tools are not selected."
xcrun --find clang >/dev/null 2>&1 || fail "Xcode Command Line Tools are incomplete."
xcodebuild -version >/dev/null 2>&1 || fail "Xcode is not usable from the command line."

available_kib="$(df -Pk "$repository_root" | awk 'NR == 2 { print $4 }')"
[[ "$available_kib" =~ ^[0-9]+$ ]] || fail "Could not determine available disk space."
minimum_kib=$((minimum_free_gib * 1024 * 1024))
(( available_kib >= minimum_kib )) \
    || fail "At least ${minimum_free_gib} GiB free is required; this volume has $((available_kib / 1024 / 1024)) GiB."
printf 'Disk space: %s GiB available (%s GiB required).\n' "$((available_kib / 1024 / 1024))" "$minimum_free_gib"

if [[ -e "$installed_app" ]]; then
    [[ -w "$installed_app" ]] || fail "VoiceInk cannot replace $installed_app with the current permissions."
else
    installed_parent="$(dirname "$installed_app")"
    [[ -d "$installed_parent" && -w "$installed_parent" ]] \
        || fail "VoiceInk cannot install to $installed_app with the current permissions."
fi

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
