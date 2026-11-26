#!/usr/bin/env bash
# Writes the metadata the Mac serves with the Android keyboard APK (GET /v1/app-update, see
# docs/phone-dictation-api.md):
#   {"applicationId":"…","versionCode":N,"versionName":"…"}
# from the output-metadata.json Gradle wrote next to the APK, so it holds exactly the values the
# APK was built with. Called by build-release.sh.
#
# Usage: apk-metadata.sh OUTPUT_METADATA_JSON DESTINATION_JSON

set -euo pipefail

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

[[ $# -eq 2 ]] || fail "Usage: $0 OUTPUT_METADATA_JSON DESTINATION_JSON"
source_file="$1"
destination="$2"

[[ -f "$source_file" ]] || fail "Gradle's APK metadata $source_file is missing."

read_field() {
    plutil -extract "$1" raw -o - "$source_file" 2>/dev/null \
        || fail "Could not read $1 from $source_file."
}

application_id="$(read_field applicationId)"
version_code="$(read_field elements.0.versionCode)"
version_name="$(read_field elements.0.versionName)"

# Checked so the values can be written as JSON without escaping.
[[ "$application_id" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]] \
    || fail "Unexpected applicationId in $source_file: $application_id"
[[ "$version_code" =~ ^[1-9][0-9]*$ ]] || fail "Unexpected versionCode in $source_file: $version_code"
[[ "$version_name" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "Unexpected versionName in $source_file: $version_name"

temporary="$destination.tmp.$$"
printf '{"applicationId":"%s","versionCode":%s,"versionName":"%s"}\n' \
    "$application_id" "$version_code" "$version_name" > "$temporary"
mv -f "$temporary" "$destination"
