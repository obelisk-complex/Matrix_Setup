#!/usr/bin/env bash
# Matrix Stack Setup — Test Utilities
# Assertion helpers and mock infrastructure for unit tests.
# shellcheck disable=SC2034
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
LIB_DIR="$PROJECT_DIR/lib"

# Test counter
_TEST_NUM=0
_TEST_FAILURES=0

# --- Source project libs in a safe way ---
# Set defaults so libs don't fail on missing globals
export NO_COLOR=1
QUIET="true"
HEADLESS="true"
SCRIPT_DIR="$PROJECT_DIR"
declare -gA CONFIG=()

# Source constants first, then utils
source "$LIB_DIR/00_constants.sh" 2>/dev/null || true
source "$LIB_DIR/01_utils.sh" 2>/dev/null || true

# --- Assertions ---

assert_eq() {
    local expected="$1"
    local actual="$2"
    local description="${3:-assert_eq}"

    _TEST_NUM=$((_TEST_NUM + 1))

    if [[ "$expected" == "$actual" ]]; then
        echo "ok $_TEST_NUM - $description"
    else
        echo "not ok $_TEST_NUM - $description"
        echo "#   expected: '$expected'"
        echo "#   actual:   '$actual'"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
}

assert_ne() {
    local unexpected="$1"
    local actual="$2"
    local description="${3:-assert_ne}"

    _TEST_NUM=$((_TEST_NUM + 1))

    if [[ "$unexpected" != "$actual" ]]; then
        echo "ok $_TEST_NUM - $description"
    else
        echo "not ok $_TEST_NUM - $description"
        echo "#   should not equal: '$unexpected'"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
}

assert_match() {
    local pattern="$1"
    local actual="$2"
    local description="${3:-assert_match}"

    _TEST_NUM=$((_TEST_NUM + 1))

    if [[ "$actual" =~ $pattern ]]; then
        echo "ok $_TEST_NUM - $description"
    else
        echo "not ok $_TEST_NUM - $description"
        echo "#   pattern: '$pattern'"
        echo "#   actual:  '$actual'"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
}

assert_no_match() {
    local pattern="$1"
    local actual="$2"
    local description="${3:-assert_no_match}"

    _TEST_NUM=$((_TEST_NUM + 1))

    if [[ ! "$actual" =~ $pattern ]]; then
        echo "ok $_TEST_NUM - $description"
    else
        echo "not ok $_TEST_NUM - $description"
        echo "#   pattern should NOT match: '$pattern'"
        echo "#   actual:  '$actual'"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
}

assert_true() {
    local description="${1:-assert_true}"
    shift

    _TEST_NUM=$((_TEST_NUM + 1))

    if "$@"; then
        echo "ok $_TEST_NUM - $description"
    else
        echo "not ok $_TEST_NUM - $description"
        echo "#   command failed: $*"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
}

assert_false() {
    local description="${1:-assert_false}"
    shift

    _TEST_NUM=$((_TEST_NUM + 1))

    if ! "$@"; then
        echo "ok $_TEST_NUM - $description"
    else
        echo "not ok $_TEST_NUM - $description"
        echo "#   command should have failed: $*"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
}

assert_file_exists() {
    local file="$1"
    local description="${2:-file exists: $file}"

    _TEST_NUM=$((_TEST_NUM + 1))

    if [[ -f "$file" ]]; then
        echo "ok $_TEST_NUM - $description"
    else
        echo "not ok $_TEST_NUM - $description"
        echo "#   file not found: $file"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local description="${3:-file contains pattern}"

    _TEST_NUM=$((_TEST_NUM + 1))

    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "ok $_TEST_NUM - $description"
    else
        echo "not ok $_TEST_NUM - $description"
        echo "#   file: $file"
        echo "#   pattern not found: $pattern"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
}

assert_exit_code() {
    local expected_code="$1"
    local description="${2:-exit code $expected_code}"
    shift 2

    _TEST_NUM=$((_TEST_NUM + 1))

    local actual_code=0
    "$@" || actual_code=$?

    if [[ "$actual_code" -eq "$expected_code" ]]; then
        echo "ok $_TEST_NUM - $description"
    else
        echo "not ok $_TEST_NUM - $description"
        echo "#   expected exit code: $expected_code"
        echo "#   actual exit code:   $actual_code"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
}

skip_test() {
    local description="$1"
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "skip $_TEST_NUM - $description"
}

# --- Temp dir for test artifacts ---
TEST_TMP=""

setup_test_tmp() {
    TEST_TMP=$(mktemp -d /tmp/matrix-test.XXXXXXXXXX)
}

teardown_test_tmp() {
    if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
        rm -rf "$TEST_TMP"
    fi
}

# --- Report ---
test_report() {
    if [[ $_TEST_FAILURES -gt 0 ]]; then
        exit 1
    fi
    exit 0
}
