#!/usr/bin/env bash
# Matrix Stack Setup — Test Runner
# Discovers and runs all test_*.sh files. TAP-compatible output.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m' RED=$'\033[0;31m' YELLOW=$'\033[0;33m'
    BOLD=$'\033[1m' DIM=$'\033[2m' RESET=$'\033[0m'
else
    GREEN='' RED='' YELLOW='' BOLD='' DIM='' RESET=''
fi

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_TESTS=()

run_test_file() {
    local test_file="$1"
    local test_name
    test_name=$(basename "$test_file" .sh)

    printf '%s--- %s ---%s\n' "$BOLD" "$test_name" "$RESET"

    local output exit_code=0
    output=$(bash "$test_file" 2>&1) || exit_code=$?

    while IFS= read -r line; do
        case "$line" in
            "ok "*)
                TESTS_RUN=$((TESTS_RUN + 1))
                TESTS_PASSED=$((TESTS_PASSED + 1))
                printf '  %s%s%s\n' "$GREEN" "$line" "$RESET"
                ;;
            "not ok "*)
                TESTS_RUN=$((TESTS_RUN + 1))
                TESTS_FAILED=$((TESTS_FAILED + 1))
                printf '  %s%s%s\n' "$RED" "$line" "$RESET"
                ;;
            "skip "*)
                TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
                printf '  %s%s%s\n' "$YELLOW" "$line" "$RESET"
                ;;
            "#"*)
                printf '  %s%s%s\n' "$DIM" "$line" "$RESET"
                ;;
            *)
                printf '  %s\n' "$line"
                ;;
        esac
    done <<< "$output"

    if [[ $exit_code -ne 0 ]]; then
        FAILED_TESTS+=("$test_name")
    fi

    return $exit_code
}

main() {
    local filter="${1:-}"

    printf '%sTAP version 14%s\n' "$DIM" "$RESET"
    printf '%sRunning tests from: %s%s\n\n' "$DIM" "$SCRIPT_DIR" "$RESET"

    local total_exit=0

    for test_file in "$SCRIPT_DIR"/test_*.sh; do
        [[ -f "$test_file" ]] || continue
        [[ "$(basename "$test_file")" == "test_runner.sh" ]] && continue
        [[ "$(basename "$test_file")" == "test_utils.sh" ]] && continue

        # Optional filter
        if [[ -n "$filter" && "$(basename "$test_file")" != *"$filter"* ]]; then
            continue
        fi

        if ! run_test_file "$test_file"; then
            total_exit=1
        fi
        echo ""
    done

    # Summary
    echo "=========================="
    printf '%sResults: %d passed, %d failed, %d skipped%s\n' \
        "$BOLD" "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_SKIPPED" "$RESET"

    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        printf '%sFailed:%s\n' "$RED" "$RESET"
        for t in "${FAILED_TESTS[@]}"; do
            printf '  %s- %s%s\n' "$RED" "$t" "$RESET"
        done
    fi

    exit $total_exit
}

main "$@"
