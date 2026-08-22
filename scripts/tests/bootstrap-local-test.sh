#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

real_git="$(command -v git)"
clone_path="$fixture_root/VoiceInk clone with spaces"
fake_bin="$fixture_root/bin"
make_log="$fixture_root/make.log"
git_log="$fixture_root/git.log"
global_git_config="$fixture_root/gitconfig"
installed_app="$fixture_root/Applications/VoiceInk.app"

mkdir -p "$clone_path/scripts" "$fake_bin" "$installed_app"
clone_path="$(cd "$clone_path" && pwd -P)"
cp "$project_root/scripts/bootstrap-local.sh" "$clone_path/scripts/bootstrap-local.sh"

"$real_git" -C "$clone_path" init -b main >/dev/null
"$real_git" -C "$clone_path" config user.name "Bootstrap Test"
"$real_git" -C "$clone_path" config user.email "bootstrap@example.com"
printf 'fixture\n' > "$clone_path/README.md"
"$real_git" -C "$clone_path" add README.md scripts/bootstrap-local.sh
"$real_git" -C "$clone_path" commit -m "test: initialize fixture" >/dev/null
"$real_git" -C "$clone_path" remote add origin https://github.com/dguay/VoiceInk.git
"$real_git" -C "$clone_path" remote add upstream git@github.com:Beingpax/VoiceInk.git
fixture_sha="$("$real_git" -C "$clone_path" rev-parse HEAD)"
"$real_git" -C "$clone_path" update-ref refs/remotes/upstream/main "$fixture_sha"

cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BOOTSTRAP_TEST_GIT_LOG"
for argument in "$@"; do
    if [[ "$argument" == "fetch" || "$argument" == "push" ]]; then
        exit 0
    fi
done
exec "$BOOTSTRAP_TEST_REAL_GIT" "$@"
EOF

cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
    exit 0
fi
if [[ "${1:-}" == "api" ]]; then
    printf 'true\n'
    exit 0
fi
exit 1
EOF

cat > "$fake_bin/xcode-select" <<'EOF'
#!/usr/bin/env bash
printf '/Applications/Xcode.app/Contents/Developer\n'
EOF

cat > "$fake_bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
printf 'Xcode 26.0\nBuild version 17A1\n'
EOF

cat > "$fake_bin/xcrun" <<'EOF'
#!/usr/bin/env bash
printf '/usr/bin/clang\n'
EOF

cat > "$fake_bin/make" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$BOOTSTRAP_TEST_MAKE_LOG"
EOF

chmod +x "$fake_bin"/* "$clone_path/scripts/bootstrap-local.sh"

run_bootstrap() {
    cd /
    PATH="$fake_bin:/usr/bin:/bin" \
        BOOTSTRAP_TEST_REAL_GIT="$real_git" \
        BOOTSTRAP_TEST_GIT_LOG="$git_log" \
        BOOTSTRAP_TEST_MAKE_LOG="$make_log" \
        GIT_CONFIG_GLOBAL="$global_git_config" \
        VOICEINK_INSTALLED_APP_PATH="$installed_app" \
        VOICEINK_MIN_FREE_GIB=0 \
        VOICEINK_UPSTREAM_REPOSITORY=someone-else/VoiceInk \
        VOICEINK_UPSTREAM_URL=https://github.com/someone-else/VoiceInk.git \
        "$clone_path/scripts/bootstrap-local.sh"
}

output="$(run_bootstrap 2>&1)"

registered_path="$(GIT_CONFIG_GLOBAL="$global_git_config" "$real_git" config --global --get voiceink.repositoryPath)"
[[ "$registered_path" == "$clone_path" ]]
grep -Fqx -- '-C' "$make_log"
grep -Fqx -- "$clone_path" "$make_log"
grep -Fqx -- 'local' "$make_log"
grep -Fqx -- "VOICEINK_FORK_COMMIT=$fixture_sha" "$make_log"
grep -Fqx -- "VOICEINK_UPSTREAM_COMMIT=$fixture_sha" "$make_log"
grep -Fq 'Warning: Codex is not installed or authenticated; continuing.' <<< "$output"
grep -Fq "Registered clone: $clone_path" <<< "$output"
grep -Fq 'push --dry-run --porcelain origin HEAD:refs/heads/voiceink-bootstrap-access-check-' "$git_log"

# These Info.plist keys are the external bundle contract consumed by SourceProvenance.
make -n -C "$project_root" local \
    VOICEINK_FORK_COMMIT=0123456789abcdef \
    VOICEINK_UPSTREAM_COMMIT=fedcba9876543210 > "$fixture_root/make-dry-run.log"
grep -Fq 'VOICEINK_FORK_COMMIT="0123456789abcdef"' "$fixture_root/make-dry-run.log"
grep -Fq 'VOICEINK_UPSTREAM_COMMIT="fedcba9876543210"' "$fixture_root/make-dry-run.log"

"$real_git" -C "$clone_path" config remote.origin.pushurl git@github.com:someone-else/VoiceInk.git
rm -f "$make_log"
set +e
invalid_push_url_output="$(run_bootstrap 2>&1)"
invalid_push_url_status=$?
set -e
[[ "$invalid_push_url_status" -ne 0 ]]
[[ ! -e "$make_log" ]]
grep -Fq "origin push URL" <<< "$invalid_push_url_output"
"$real_git" -C "$clone_path" config --unset-all remote.origin.pushurl

chmod 500 "$(dirname "$installed_app")"
rm -f "$make_log"
set +e
invalid_install_output="$(run_bootstrap 2>&1)"
invalid_install_status=$?
set -e
chmod 700 "$(dirname "$installed_app")"
[[ "$invalid_install_status" -ne 0 ]]
[[ ! -e "$make_log" ]]
grep -Fq "cannot replace $installed_app" <<< "$invalid_install_output"

"$real_git" -C "$clone_path" remote set-url origin https://github.com/someone-else/VoiceInk.git
rm -f "$make_log"
set +e
invalid_remote_output="$(run_bootstrap 2>&1)"
invalid_remote_status=$?
set -e

[[ "$invalid_remote_status" -ne 0 ]]
[[ ! -e "$make_log" ]]
grep -Fq "expected dguay/voiceink" <<< "$invalid_remote_output"

printf 'bootstrap-local-test: PASS\n'
