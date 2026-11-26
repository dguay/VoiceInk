#!/usr/bin/env bash
# Prints the Android version derived from the fork's Git history, read by app/build.gradle.kts:
#   versionCode=<number of first-parent commits of HEAD>
#   versionName=0.1.<versionCode>-<12-character commit SHA>
# Each fork commit on main adds one first-parent commit, so a later commit always has a greater
# versionCode and `adb install -r` accepts it. Fails, rather than guess, outside a full clone.

set -euo pipefail

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

repository="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

[[ "$(git -C "$repository" rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] \
    || fail "The Android version comes from Git, but $repository is not in a Git checkout. Build from a clone of the fork."
[[ "$(git -C "$repository" rev-parse --is-shallow-repository)" == "false" ]] \
    || fail "The Android version counts Git commits, but this clone is shallow. Run 'git fetch --unshallow' first."

count="$(git -C "$repository" rev-list --count --first-parent HEAD)" \
    || fail "Could not count the Git commits of HEAD."
sha="$(git -C "$repository" rev-parse --short=12 HEAD)" \
    || fail "Could not read the Git commit of HEAD."
[[ "$count" =~ ^[1-9][0-9]*$ ]] || fail "Unexpected Git commit count: $count"

printf 'versionCode=%s\n' "$count"
printf 'versionName=0.1.%s-%s\n' "$count" "$sha"
