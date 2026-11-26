#!/usr/bin/env bash
# Manages the Android release signing key in this Mac's login Keychain.
#
#   release-key.sh check        exit 0 when the key is in the Keychain, 1 when it is missing
#   release-key.sh create       generate the key once, on the first Mac, and store it
#   release-key.sh export FILE  write an owner-only file to carry the key to another Mac
#   release-key.sh import FILE  store the key from such a file in this Mac's Keychain
#
# The key and its password are never printed and never passed on a command line.
# Tests override the tools with VOICEINK_SECURITY_BIN and VOICEINK_KEYTOOL_BIN.

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=release-key-common.sh
source "$script_directory/release-key-common.sh"

readonly export_header="voiceink-android-release-key v1"
readonly key_dname="CN=VoiceInk Keyboard, O=VoiceInk fork"

# Private temporary folder of create and import, removed however the script ends.
work=""
trap '[[ -z "$work" ]] || rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
    printf 'Usage: %s check | create | export FILE | import FILE\n' "$(basename "$0")" >&2
    exit 2
}

refuse_if_present() {
    local status=0
    release_key_status || status=$?
    if (( status == 0 )); then
        fail "An Android release key is already in this Keychain. Keep it: APKs signed with another key cannot install over the app. To replace it on purpose, first delete it with: security delete-generic-password -s $release_key_service -a keystore; security delete-generic-password -s $release_key_service -a password"
    fi
    # A partial key (one item only) is replaced; a Keychain error stops here.
    (( status == 44 )) || require_release_key
}

store_release_key() {
    local keystore_base64="$1"
    local password="$2"
    # `check` needs both items, so a run stopped between the two writes leaves the key reported
    # missing, and the next create or import replaces the partial item.
    keychain_write password "$password"
    keychain_write keystore "$keystore_base64"
}

check_command() {
    local status=0
    release_key_status || status=$?
    case "$status" in
        0) printf 'Android release key: present in the Keychain (%s).\n' "$release_key_service" ;;
        44) printf 'Android release key: missing from the Keychain (%s, account %s). %s\n' \
                "$release_key_service" "$release_key_missing_account" "$(release_key_setup_hint)" >&2
            exit 1 ;;
        *) printf 'Android release key: could not read the Keychain (%s, security exit %s). Unlock the login Keychain and try again.\n' \
                "$release_key_service" "$status" >&2
            exit 1 ;;
    esac
}

create_command() {
    local keystore_file password keystore_base64 keytool_log

    refuse_if_present

    work="$(make_private_directory)"
    keystore_file="$work/release.p12"
    keytool_log="$work/keytool.log"
    password="$(openssl rand -hex 32)" || fail "Could not generate a password with openssl."
    [[ "$password" =~ ^[0-9a-f]{64}$ ]] || fail "openssl did not return a random password."

    # EC P-256 rather than RSA 4096: same strength class as RSA 3072, and the keystore fits in
    # one `security -i` input line (see release-key-common.sh). Validity: about 50 years.
    if ! VOICEINK_ANDROID_KEYTOOL_PASSWORD="$password" "$keytool_bin" -genkeypair \
        -keystore "$keystore_file" -storetype PKCS12 \
        -storepass:env VOICEINK_ANDROID_KEYTOOL_PASSWORD -keypass:env VOICEINK_ANDROID_KEYTOOL_PASSWORD \
        -alias "$release_key_alias" -keyalg EC -groupname secp256r1 -sigalg SHA256withECDSA \
        -validity 18250 -dname "$key_dname" > "$keytool_log" 2>&1; then
        cat "$keytool_log" >&2
        fail "keytool could not generate the Android release keystore."
    fi
    verify_keystore "$keystore_file" "$password" \
        || fail "The generated Android keystore does not open with its password."

    keystore_base64="$(base64 < "$keystore_file" | tr -d '\n')"
    (( ${#keystore_base64} <= release_key_max_keystore_chars )) \
        || fail "The generated keystore is too large to store in the Keychain."

    store_release_key "$keystore_base64" "$password"
    printf 'Created the Android release key and stored it in the Keychain (%s).\n' "$release_key_service"
    printf 'Copy it to your other Macs with: android/scripts/release-key.sh export FILE\n'
}

export_command() {
    local destination="$1"
    local keystore_base64 password

    [[ ! -e "$destination" ]] || fail "$destination already exists; choose a new file."
    [[ -d "$(dirname "$destination")" ]] || fail "The folder for $destination does not exist."
    if git -C "$(dirname "$destination")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        fail "Refusing to export the key into a Git working tree ($destination). Choose a folder outside any repository, for example ~/Desktop."
    fi

    require_release_key
    keystore_base64="$(keychain_read keystore)" || fail "Could not read the Android keystore from the Keychain."
    password="$(keychain_read password)" || fail "Could not read the Android keystore password from the Keychain."

    write_private_file "$destination" "$export_header
password=$password
keystore=$keystore_base64
"
    printf 'Wrote the Android release key to %s (owner-only).\n' "$destination"
    printf 'Warning: this file holds the signing key and its password. Copy it to the other Mac\n'
    printf 'directly (AirDrop or a USB drive, not a cloud folder or chat), run\n'
    printf '"android/scripts/release-key.sh import FILE" there, then delete the file on both Macs.\n'
}

import_command() {
    local source_file="$1"
    local header="" password="" keystore_base64="" line keystore_file

    [[ -f "$source_file" && -r "$source_file" ]] || fail "Cannot read $source_file."
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$export_header") header=1 ;;
            password=*) password="${line#password=}" ;;
            keystore=*) keystore_base64="${line#keystore=}" ;;
            "") ;;
            *) fail "$source_file is not an Android release key export (unexpected line)." ;;
        esac
    done < "$source_file"
    [[ -n "$header" && -n "$password" && -n "$keystore_base64" ]] \
        || fail "$source_file is not an Android release key export from release-key.sh."
    [[ "$password" =~ ^[A-Za-z0-9]+$ ]] || fail "$source_file holds an invalid password."
    [[ "$keystore_base64" =~ ^[A-Za-z0-9+/=]+$ ]] || fail "$source_file holds an invalid keystore."
    (( ${#keystore_base64} <= release_key_max_keystore_chars )) \
        || fail "The keystore in $source_file is too large to store in the Keychain."

    refuse_if_present

    work="$(make_private_directory)"
    keystore_file="$work/release.p12"
    write_keystore_file "$keystore_base64" "$keystore_file"
    verify_keystore "$keystore_file" "$password" \
        || fail "The keystore in $source_file does not open with its password, or has no '$release_key_alias' key."

    store_release_key "$keystore_base64" "$password"
    printf 'Imported the Android release key into the Keychain (%s).\n' "$release_key_service"
    printf 'Delete %s now that it is imported.\n' "$source_file"
}

case "${1:-}" in
    check) (( $# == 1 )) || usage; check_command ;;
    create) (( $# == 1 )) || usage; create_command ;;
    export) (( $# == 2 )) || usage; export_command "$2" ;;
    import) (( $# == 2 )) || usage; import_command "$2" ;;
    *) usage ;;
esac
