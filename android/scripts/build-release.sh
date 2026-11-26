#!/usr/bin/env bash
# Builds the signed release APK (app/build/outputs/apk/release/app-release.apk) with the
# release key from this Mac's login Keychain. Extra arguments go to Gradle.
#
# The keystore and its password are written to owner-only files in a private temporary folder
# that is removed when the build ends; Gradle gets only their paths. Nothing secret is printed,
# passed on a command line, or placed in Gradle's environment.

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
android_directory="$(cd "$script_directory/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=release-key-common.sh
source "$script_directory/release-key-common.sh"

require_release_key

work="$(make_private_directory)"
cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

keystore_file="$work/release.p12"
password_file="$work/password"

keystore_base64="$(keychain_read keystore)" || fail "Could not read the Android keystore from the Keychain."
password="$(keychain_read password)" || fail "Could not read the Android keystore password from the Keychain."
write_keystore_file "$keystore_base64" "$keystore_file"
write_private_file "$password_file" "$password"
unset keystore_base64 password

release_directory="$android_directory/app/build/outputs/apk/release"
apk="$release_directory/app-release.apk"
# What the Mac serves with the APK so the phone can update itself (see android/README.md).
metadata="$release_directory/VoiceInkKeyboard.json"
# Never leave the metadata of an earlier build next to a new APK.
rm -f "$metadata"

printf 'Building the signed Android release APK with the Keychain key (%s)...\n' "$release_key_service"
(
    cd "$android_directory"
    # No daemon: no Gradle process outlives the build. No configuration cache: the signing
    # configuration, which holds the password, is never serialized to disk.
    VOICEINK_ANDROID_KEYSTORE_FILE="$keystore_file" \
        VOICEINK_ANDROID_KEYSTORE_PASSWORD_FILE="$password_file" \
        ./gradlew --no-daemon --no-configuration-cache assembleRelease "$@"
)

[[ -f "$apk" ]] || fail "Gradle finished but $apk is missing."
"$script_directory/apk-metadata.sh" "$release_directory/output-metadata.json" "$metadata"
printf 'Signed release APK: %s\n' "$apk"
printf 'APK metadata: %s\n' "$metadata"
printf 'To offer it to the phone from a Mac, copy both into VoiceInk.app/Contents/Resources/AndroidKeyboard/ as VoiceInkKeyboard.apk and VoiceInkKeyboard.json.\n'
printf 'Install over the previous release build with: adb install -r %s\n' "$apk"
