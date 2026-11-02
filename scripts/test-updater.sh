#!/usr/bin/env bash
# Runs every updater shell test suite, reports each one, and fails if any fails.
# Each suite stays runnable on its own: bash scripts/tests/<suite>.sh

set -uo pipefail

readonly suites=(
    test-updater-test.sh
    bootstrap-local-test.sh
    prepare-local-update-test.sh
    install-local-update-test.sh
    restore-local-update-test.sh
)

tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/tests" && pwd)" || {
    printf 'Error: updater test directory is missing.\n' >&2
    exit 1
}

failed=()
for suite in "${suites[@]}"; do
    suite_path="$tests_directory/$suite"
    if [[ ! -f "$suite_path" ]]; then
        printf 'FAIL %s (missing: %s)\n' "$suite" "$suite_path"
        failed+=("$suite")
        continue
    fi

    printf '==> %s\n' "$suite"
    if bash "$suite_path"; then
        printf 'PASS %s\n' "$suite"
    else
        printf 'FAIL %s (exit %s)\n' "$suite" "$?"
        failed+=("$suite")
    fi
done

if (( ${#failed[@]} > 0 )); then
    printf 'Updater tests: %s of %s suites failed: %s\n' \
        "${#failed[@]}" "${#suites[@]}" "${failed[*]}" >&2
    exit 1
fi

printf 'Updater tests: all %s suites passed.\n' "${#suites[@]}"
