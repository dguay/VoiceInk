#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/voiceink-test-updater-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

suites=(
    test-updater-test.sh
    bootstrap-local-test.sh
    prepare-local-update-test.sh
    install-local-update-test.sh
    restore-local-update-test.sh
)

mkdir -p "$fixture_root/scripts/tests"
cp "$project_root/scripts/test-updater.sh" "$fixture_root/scripts/test-updater.sh"

write_suite() {
    local suite="$1"
    local status="$2"
    printf '#!/usr/bin/env bash\nprintf "ran %%s\\n" "%s" >> "%s/ran.log"\nexit %s\n' \
        "$suite" "$fixture_root" "$status" > "$fixture_root/scripts/tests/$suite"
}

run_runner() {
    rm -f "$fixture_root/ran.log"
    set +e
    output="$(bash "$fixture_root/scripts/test-updater.sh" 2>&1)"
    status=$?
    set -e
}

for suite in "${suites[@]}"; do
    write_suite "$suite" 0
done

run_runner
[[ "$status" -eq 0 ]]
for suite in "${suites[@]}"; do
    grep -Fqx "PASS $suite" <<< "$output"
    grep -Fqx "ran $suite" "$fixture_root/ran.log"
done
grep -Fq 'all 5 suites passed' <<< "$output"

# A failing suite fails the run, and later suites still run and report.
write_suite prepare-local-update-test.sh 3
run_runner
[[ "$status" -ne 0 ]]
grep -Fqx 'FAIL prepare-local-update-test.sh (exit 3)' <<< "$output"
grep -Fqx 'PASS install-local-update-test.sh' <<< "$output"
grep -Fqx 'PASS restore-local-update-test.sh' <<< "$output"
grep -Fqx 'ran restore-local-update-test.sh' "$fixture_root/ran.log"
grep -Fq '1 of 5 suites failed: prepare-local-update-test.sh' <<< "$output"
write_suite prepare-local-update-test.sh 0

# A missing suite fails the run instead of being skipped silently.
rm "$fixture_root/scripts/tests/restore-local-update-test.sh"
run_runner
[[ "$status" -ne 0 ]]
grep -Fq 'FAIL restore-local-update-test.sh (missing:' <<< "$output"
grep -Fq '1 of 5 suites failed: restore-local-update-test.sh' <<< "$output"

printf 'test-updater-test: PASS\n'
