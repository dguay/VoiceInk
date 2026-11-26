# shellcheck shell=bash
# Shared by release-key.sh and build-release.sh; sourced, not executed.
#
# The Android release signing key lives in the login Keychain as two generic passwords:
#   service voiceink-android-release, account "keystore": base64 of a PKCS12 keystore
#   service voiceink-android-release, account "password": the keystore and key password
# Secrets are read with `security ... -w` into shell variables and written through `security -i`
# on stdin, so they never appear on a command line, in Gradle's environment, or in any output.

readonly release_key_service="voiceink-android-release"
readonly release_key_alias="voiceink"
# `security -i` reads one command per line and splits lines longer than about 4 KiB, so the
# base64 keystore must stay well under that. An EC P-256 keystore is about 1.4 KiB of base64
# (an RSA 4096 one is about 5.7 KiB and would not fit).
# shellcheck disable=SC2034 # used by release-key.sh
readonly release_key_max_keystore_chars=3500

security_bin="${VOICEINK_SECURITY_BIN:-/usr/bin/security}"
if [[ -n "${VOICEINK_KEYTOOL_BIN:-}" ]]; then
    keytool_bin="$VOICEINK_KEYTOOL_BIN"
elif [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/keytool" ]]; then
    keytool_bin="$JAVA_HOME/bin/keytool"
else
    keytool_bin="keytool"
fi
# Optional keychain file; empty (the default) means the user's default, login, keychain.
release_keychain="${VOICEINK_ANDROID_KEYCHAIN:-}"

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

release_key_setup_hint() {
    printf '%s' "Create it on the first Mac with 'android/scripts/release-key.sh create', or copy it from a Mac that has it ('android/scripts/release-key.sh export FILE' there, then 'android/scripts/release-key.sh import FILE' here). See android/README.md."
}

# Runs `security COMMAND ARGS... [keychain]`.
run_security() {
    local command="$1"
    shift
    if [[ -n "$release_keychain" ]]; then
        "$security_bin" "$command" "$@" "$release_keychain"
    else
        "$security_bin" "$command" "$@"
    fi
}

# Prints the item's secret on stdout. Status: 0 found, 44 missing, other: Keychain error.
keychain_read() {
    run_security find-generic-password -s "$release_key_service" -a "$1" -w 2>/dev/null
}

# Status: 0 present, 44 missing, other: Keychain error. Never prints the secret.
keychain_item_status() {
    run_security find-generic-password -s "$release_key_service" -a "$1" >/dev/null 2>&1
}

# Stores the value through `security -i` on stdin, then reads it back to confirm.
keychain_write() {
    local account="$1"
    local value="$2"
    local stored

    [[ "$value" =~ ^[A-Za-z0-9+/=]+$ ]] \
        || fail "Refusing to store a Keychain value with unexpected characters."
    [[ -z "$release_keychain" || "$release_keychain" =~ ^[^[:space:]\"\']+$ ]] \
        || fail "VOICEINK_ANDROID_KEYCHAIN must be a path without spaces or quotes."

    printf 'add-generic-password -U -s %s -a %s -w %s %s\n' \
        "$release_key_service" "$account" "$value" "$release_keychain" \
        | "$security_bin" -i >/dev/null 2>&1 || true

    stored="$(keychain_read "$account")" && [[ "$stored" == "$value" ]] \
        || fail "Could not store account '$account' in the Keychain item '$release_key_service' (is the login Keychain unlocked?)."
}

keychain_delete() {
    run_security delete-generic-password -s "$release_key_service" -a "$1" >/dev/null 2>&1 || true
}

# Status 0 when both items are present, 44 when one is missing, other: Keychain error.
# Sets release_key_missing_account to the first missing or unreadable account.
release_key_status() {
    local account status
    release_key_missing_account=""
    for account in keystore password; do
        status=0
        keychain_item_status "$account" || status=$?
        if (( status != 0 )); then
            release_key_missing_account="$account"
            return "$status"
        fi
    done
}

# Exits with a clear message unless both Keychain items are present.
require_release_key() {
    local status=0
    release_key_status || status=$?
    case "$status" in
        0) ;;
        44) fail "The Android release key is missing from this Mac's Keychain (generic password service '$release_key_service', account '$release_key_missing_account'). $(release_key_setup_hint)" ;;
        *) fail "Could not read the Keychain item '$release_key_service' (account '$release_key_missing_account', security exit $status). Unlock the login Keychain and try again." ;;
    esac
}

# Creates an owner-only temporary directory and prints its path.
make_private_directory() {
    local directory
    directory="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/voiceink-android-release.XXXXXX")" \
        || fail "Could not create a temporary directory."
    chmod 700 "$directory"
    printf '%s\n' "$directory"
}

# Writes an owner-only file holding the value, without a trailing newline.
write_private_file() {
    local path="$1"
    local value="$2"
    ( umask 077 && printf '%s' "$value" > "$path" ) || fail "Could not write $path."
    chmod 600 "$path"
}

# Decodes the base64 keystore into an owner-only file.
write_keystore_file() {
    local keystore_base64="$1"
    local path="$2"
    ( umask 077 && printf '%s' "$keystore_base64" | base64 -d > "$path" 2>/dev/null ) \
        || fail "The Android keystore is not valid base64."
    chmod 600 "$path"
    [[ -s "$path" ]] || fail "The Android keystore is empty."
}

# Status 0 when the keystore opens with the password and holds the signing key alias.
verify_keystore() {
    local keystore_file="$1"
    local password="$2"
    VOICEINK_ANDROID_KEYTOOL_PASSWORD="$password" "$keytool_bin" -list \
        -keystore "$keystore_file" -storetype PKCS12 \
        -storepass:env VOICEINK_ANDROID_KEYTOOL_PASSWORD -alias "$release_key_alias" >/dev/null 2>&1
}
