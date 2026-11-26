#!/usr/bin/env bash
# Tests the Android release key scripts and the Git-derived version, with stubbed `security`,
# `keytool` and `gradlew`, so the real Keychain and the Android SDK are never used.

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/voiceink-android-release-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
fixture_root="$(cd "$fixture_root" && pwd -P)"
# Git must not find a repository above the fixture (TMPDIR can be inside a clone).
export GIT_CEILING_DIRECTORIES="$fixture_root"

android_copy="$fixture_root/android"
fake_bin="$fixture_root/bin"
private_tmp="$fixture_root/tmp"
mkdir -p "$android_copy/scripts" "$fake_bin" "$private_tmp" "$fixture_root/mac-a" "$fixture_root/mac-b"
cp "$project_root/android/scripts/release-key.sh" \
    "$project_root/android/scripts/release-key-common.sh" \
    "$project_root/android/scripts/build-release.sh" \
    "$project_root/android/scripts/version.sh" \
    "$android_copy/scripts/"

expect() {
    local description="$1"
    shift
    if ! "$@"; then
        printf 'android-release-test: FAIL: %s\n' "$description" >&2
        exit 1
    fi
}

# A Keychain stored as one file per item in $FAKE_KEYCHAIN_DIR. Logs every command line.
cat > "$fake_bin/security" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SECURITY_LOG"
item_command() {
    local command="$1"; shift
    local service="" account="" print_secret="" token=""
    while (( $# > 0 )); do
        case "$1" in
            -s) service="$2"; shift 2 ;;
            -a) account="$2"; shift 2 ;;
            -w) if [[ "$command" == add-generic-password ]]; then token="$2"; shift 2; else print_secret=1; shift; fi ;;
            -U) shift ;;
            *) shift ;;
        esac
    done
    local item="$FAKE_KEYCHAIN_DIR/$service.$account"
    case "$command" in
        find-generic-password)
            [[ -f "$item" ]] || { echo "security: item could not be found" >&2; return 44; }
            [[ -n "$print_secret" ]] && cat "$item" && echo
            return 0 ;;
        add-generic-password) printf '%s' "$token" > "$item" ;;
        delete-generic-password) [[ -f "$item" ]] || return 44; rm -f "$item" ;;
        *) return 1 ;;
    esac
}
if [[ "${1:-}" == "-i" ]]; then
    while read -r -a words; do
        (( ${#words[@]} > 0 )) && item_command "${words[@]}"
    done
    exit 0
fi
item_command "$@"
EOF

# keytool stub: a "keystore" is the text fake-keystore:<password>, so -list checks the password.
cat > "$fake_bin/keytool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_KEYTOOL_LOG"
mode="$1"; shift
keystore="" password_variable="" alias=""
while (( $# > 0 )); do
    case "$1" in
        -keystore) keystore="$2"; shift 2 ;;
        -storepass:env) password_variable="$2"; shift 2 ;;
        -alias) alias="$2"; shift 2 ;;
        *) shift ;;
    esac
done
password="${!password_variable}"
case "$mode" in
    -genkeypair) [[ -z "${FAKE_KEYTOOL_FAIL:-}" ]] || { echo "keytool error: fake" >&2; exit 1; }
                 printf 'fake-keystore:%s:%s' "$alias" "$password" > "$keystore" ;;
    -list) [[ "$(cat "$keystore")" == "fake-keystore:$alias:$password" ]] ;;
    *) exit 1 ;;
esac
EOF

# gradlew stub: records what Gradle would receive and produces the APK.
cat > "$android_copy/gradlew" <<'EOF'
#!/usr/bin/env bash
{
    printf 'args=%s\n' "$*"
    printf 'keystore_file=%s\n' "$VOICEINK_ANDROID_KEYSTORE_FILE"
    printf 'password_file=%s\n' "$VOICEINK_ANDROID_KEYSTORE_PASSWORD_FILE"
    printf 'keystore_mode=%s\n' "$(stat -f %Lp "$VOICEINK_ANDROID_KEYSTORE_FILE")"
    printf 'password_mode=%s\n' "$(stat -f %Lp "$VOICEINK_ANDROID_KEYSTORE_PASSWORD_FILE")"
    printf 'directory_mode=%s\n' "$(stat -f %Lp "$(dirname "$VOICEINK_ANDROID_KEYSTORE_FILE")")"
    printf 'keystore=%s\n' "$(cat "$VOICEINK_ANDROID_KEYSTORE_FILE")"
    printf 'password=%s\n' "$(cat "$VOICEINK_ANDROID_KEYSTORE_PASSWORD_FILE")"
} > "$FAKE_GRADLE_LOG"
env > "$FAKE_GRADLE_ENV"
[[ -z "${FAKE_GRADLE_FAIL:-}" ]] || exit 1
mkdir -p app/build/outputs/apk/release
printf 'apk' > app/build/outputs/apk/release/app-release.apk
EOF
chmod +x "$fake_bin"/* "$android_copy/gradlew"

security_log="$fixture_root/security.log"
keytool_log="$fixture_root/keytool.log"
gradle_log="$fixture_root/gradle.log"
gradle_env="$fixture_root/gradle.env"

# Runs a script as "Mac A" or "Mac B" (separate fake keychains); sets output and status.
run_on() {
    local mac="$1"
    shift
    set +e
    output="$(PATH="$fake_bin:/usr/bin:/bin" TMPDIR="$private_tmp" \
        VOICEINK_SECURITY_BIN="$fake_bin/security" VOICEINK_KEYTOOL_BIN="$fake_bin/keytool" \
        FAKE_KEYCHAIN_DIR="$fixture_root/$mac" FAKE_SECURITY_LOG="$security_log" \
        FAKE_KEYTOOL_LOG="$keytool_log" FAKE_GRADLE_LOG="$gradle_log" FAKE_GRADLE_ENV="$gradle_env" \
        "$@" 2>&1)"
    status=$?
    set -e
}

private_tmp_is_empty() {
    [[ -z "$(ls -A "$private_tmp")" ]]
}

key_script="$android_copy/scripts/release-key.sh"
build_script="$android_copy/scripts/build-release.sh"

# --- Missing key: check and the release build stop with the item and the fix.
run_on mac-a bash "$key_script" check
expect "check fails without the key" test "$status" -eq 1
expect "check names the missing item" grep -Fq "voiceink-android-release, account keystore" <<< "$output"
expect "check names the create command" grep -Fq "release-key.sh create" <<< "$output"

run_on mac-a bash "$build_script"
expect "release build fails without the key" test "$status" -ne 0
expect "release build names the missing item" grep -Fq "missing from this Mac's Keychain (generic password service 'voiceink-android-release', account 'keystore')" <<< "$output"
expect "release build names the import command" grep -Fq "release-key.sh import FILE" <<< "$output"
expect "Gradle does not run without the key" test ! -e "$gradle_log"

# --- create: generates the keystore, stores both items, never shows the secrets.
run_on mac-a env FAKE_KEYTOOL_FAIL=1 bash "$key_script" create
expect "create reports a keytool failure" test "$status" -ne 0
expect "a failed create stores nothing" test -z "$(ls -A "$fixture_root/mac-a")"
expect "a failed create removes its temporary files" private_tmp_is_empty

run_on mac-a bash "$key_script" create
expect "create succeeds" test "$status" -eq 0
password="$(cat "$fixture_root/mac-a/voiceink-android-release.password")"
keystore_base64="$(cat "$fixture_root/mac-a/voiceink-android-release.keystore")"
expect "create stores a random 64-hex password" grep -Eqx '[0-9a-f]{64}' <<< "$password"
expect "create stores the keystore as base64" \
    test "$(printf '%s' "$keystore_base64" | base64 -d)" == "fake-keystore:voiceink:$password"
expect "create generates an EC P-256 key" grep -Fq -- "-keyalg EC -groupname secp256r1" "$keytool_log"
expect "create removes its temporary keystore" private_tmp_is_empty
expect "create does not print the password" bash -c '! grep -Fq "$1" <<< "$2"' _ "$password" "$output"

run_on mac-a bash "$key_script" check
expect "check passes with the key" test "$status" -eq 0
expect "check reports the key present" grep -Fq "Android release key: present" <<< "$output"

run_on mac-a bash "$key_script" create
expect "create refuses to replace an existing key" test "$status" -ne 0
expect "create explains why it refuses" grep -Fq "already in this Keychain" <<< "$output"
expect "the existing password is kept" test "$(cat "$fixture_root/mac-a/voiceink-android-release.password")" == "$password"

# --- build-release: Gradle gets owner-only temporary files, removed afterwards.
run_on mac-a bash "$build_script" --offline
expect "release build succeeds" test "$status" -eq 0
expect "release build runs assembleRelease" grep -Fqx "args=--no-daemon --no-configuration-cache assembleRelease --offline" "$gradle_log"
expect "Gradle gets the keystore" grep -Fqx "keystore=fake-keystore:voiceink:$password" "$gradle_log"
expect "Gradle gets the password file" grep -Fqx "password=$password" "$gradle_log"
expect "the keystore file is owner-only" grep -Fqx "keystore_mode=600" "$gradle_log"
expect "the password file is owner-only" grep -Fqx "password_mode=600" "$gradle_log"
expect "the temporary folder is owner-only" grep -Fqx "directory_mode=700" "$gradle_log"
keystore_path="$(sed -n 's/^keystore_file=//p' "$gradle_log")"
expect "the keystore is outside the Android project" bash -c '[[ "$1" != "$2"/* ]]' _ "$keystore_path" "$android_copy"
expect "the temporary files are removed after the build" private_tmp_is_empty
expect "the password is not in Gradle's environment" bash -c '! grep -Fq "$1" "$2"' _ "$password" "$gradle_env"
expect "the keystore is not in Gradle's environment" bash -c '! grep -Fq "$1" "$2"' _ "$keystore_base64" "$gradle_env"
expect "the build output does not show the password" bash -c '! grep -Fq "$1" <<< "$2"' _ "$password" "$output"
expect "the build reports the APK" grep -Fq "Signed release APK: $android_copy/app/build/outputs/apk/release/app-release.apk" <<< "$output"

run_on mac-a env FAKE_GRADLE_FAIL=1 bash "$build_script"
expect "a failed Gradle build fails the release build" test "$status" -ne 0
expect "a failed build removes the temporary files" private_tmp_is_empty

# --- export: an owner-only file, never inside a Git working tree.
mkdir -p "$fixture_root/some-repository"
git init -q "$fixture_root/some-repository"
run_on mac-a bash "$key_script" export "$fixture_root/some-repository/key.txt"
expect "export refuses a Git working tree" test "$status" -ne 0
expect "export writes nothing into the working tree" test ! -e "$fixture_root/some-repository/key.txt"

export_file="$fixture_root/transfer/voiceink-key.txt"
mkdir -p "$fixture_root/transfer"
run_on mac-a bash "$key_script" export "$export_file"
expect "export succeeds" test "$status" -eq 0
expect "the export file is owner-only" test "$(stat -f %Lp "$export_file")" == 600
expect "export warns to delete the file" grep -Fq "delete the file on both Macs" <<< "$output"
expect "export does not print the password" bash -c '! grep -Fq "$1" <<< "$2"' _ "$password" "$output"

run_on mac-a bash "$key_script" export "$export_file"
expect "export refuses to overwrite a file" test "$status" -ne 0

# --- import on a second Mac: the same key, checked before it is stored.
broken_file="$fixture_root/transfer/broken.txt"
sed "s/^password=.*/password=0000/" "$export_file" > "$broken_file"
run_on mac-b bash "$key_script" import "$broken_file"
expect "import rejects a wrong password" test "$status" -ne 0
expect "a rejected import stores nothing" test -z "$(ls -A "$fixture_root/mac-b")"
expect "a rejected import removes its temporary files" private_tmp_is_empty

printf 'not a key\n' > "$broken_file"
run_on mac-b bash "$key_script" import "$broken_file"
expect "import rejects an unrelated file" test "$status" -ne 0

run_on mac-b bash "$key_script" import "$export_file"
expect "import succeeds" test "$status" -eq 0
expect "import stores the same password" \
    test "$(cat "$fixture_root/mac-b/voiceink-android-release.password")" == "$password"
expect "import stores the same keystore" \
    test "$(cat "$fixture_root/mac-b/voiceink-android-release.keystore")" == "$keystore_base64"
expect "import removes its temporary files" private_tmp_is_empty

run_on mac-b bash "$key_script" import "$export_file"
expect "import refuses to replace an existing key" test "$status" -ne 0

# Secrets travel on stdin to `security -i`, never on a command line.
expect "no security command line holds the password" bash -c '! grep -Fq "$1" "$2"' _ "$password" "$security_log"
expect "no security command line holds the keystore" bash -c '! grep -Fq "$1" "$2"' _ "$keystore_base64" "$security_log"
expect "no keytool command line holds the password" bash -c '! grep -Fq "$1" "$2"' _ "$password" "$keytool_log"

# --- version.sh: a later commit has a greater versionCode; the name carries the SHA.
version_repository="$fixture_root/version-repository"
git init -q -b main "$version_repository"
git -C "$version_repository" config user.name "Android Release Test"
git -C "$version_repository" config user.email "android-release@example.com"
commit() {
    printf "%s\n" "$1" > "$version_repository/$1"
    git -C "$version_repository" add "$1"
    git -C "$version_repository" commit -q -m "$1"
}
version_field() {
    sed -n "s/^$1=//p" <<< "$2"
}

commit first
earlier="$(bash "$android_copy/scripts/version.sh" "$version_repository")"
earlier_code="$(version_field versionCode "$earlier")"
expect "the first commit has versionCode 1" test "$earlier_code" -eq 1
expect "versionName carries the commit SHA" \
    test "$(version_field versionName "$earlier")" == "0.1.1-$(git -C "$version_repository" rev-parse --short=12 HEAD)"

git -C "$version_repository" checkout -q -b feature
commit feature-one
commit feature-two
git -C "$version_repository" checkout -q main
commit second
git -C "$version_repository" merge -q --no-ff --no-edit feature
later="$(bash "$android_copy/scripts/version.sh" "$version_repository")"
later_code="$(version_field versionCode "$later")"
expect "a later commit has a greater versionCode" test "$later_code" -gt "$earlier_code"
expect "the code counts first-parent commits" test "$later_code" -eq 3
expect "a later commit has another versionName" \
    test "$(version_field versionName "$later")" != "$(version_field versionName "$earlier")"

set +e
outside_output="$(bash "$android_copy/scripts/version.sh" "$private_tmp" 2>&1)"
outside_status=$?
shallow_clone="$fixture_root/shallow"
git clone -q --depth 1 "file://$version_repository" "$shallow_clone"
shallow_output="$(bash "$android_copy/scripts/version.sh" "$shallow_clone" 2>&1)"
shallow_status=$?
set -e
expect "version fails outside Git" test "$outside_status" -ne 0
expect "version explains it needs Git" grep -Fq "is not in a Git checkout" <<< "$outside_output"
expect "version fails in a shallow clone" test "$shallow_status" -ne 0
expect "version explains the shallow clone" grep -Fq "git fetch --unshallow" <<< "$shallow_output"

# The app build reads its version from version.sh and gates release builds on the key.
gradle_file="$project_root/android/app/build.gradle.kts"
expect "the app build uses version.sh" grep -Fq 'rootDir.resolve("scripts/version.sh")' "$gradle_file"
expect "the app build has no fixed versionCode" bash -c '! grep -Eq "versionCode = [0-9]" "$1"' _ "$gradle_file"
expect "the app build gates release builds" grep -Fq 'tasks.named { it == "preReleaseBuild" }.configureEach { dependsOn(checkReleaseSigning) }' "$gradle_file"

printf 'android-release-test: PASS\n'
