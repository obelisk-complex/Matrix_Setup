#!/usr/bin/env bash
# Tests for the test harnesses themselves: tests/test_runner.sh's failure
# reporting, and the error message tests/distro/test_integration.sh greps for.
# Every other test result is read through these, so they need controls proving
# they can still go red.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"

setup_test_tmp
trap teardown_test_tmp EXIT

# test_utils.sh reassigns SCRIPT_DIR to the project root; TEST_DIR is the
# tests/ directory this file lives in.
RUNNER="$TEST_DIR/test_runner.sh"

# The runner discovers test_*.sh next to itself, so each scenario gets its own
# directory holding a copy of the runner and exactly one test file.
_run_runner_over() {
    local dir="$TEST_TMP/$1" body="$2"
    mkdir -p "$dir"
    cp "$RUNNER" "$TEST_DIR/test_utils.sh" "$dir/"
    printf '%s\n' "$body" > "$dir/test_fixture.sh"
    local rc=0
    bash "$dir/test_runner.sh" >"$dir/out.txt" 2>&1 || rc=$?
    printf '%s\n' "$rc"
}

# --- Test: a file that reports failures but exits 0 still fails the runner ---
# This is the malformed case: TAP "not ok" lines emitted, trailing test_report
# omitted, so the child exits 0. The summary counter must reach the exit code.
rc=$(_run_runner_over malformed 'echo "ok 1 - passing"
echo "not ok 2 - failing"
exit 0')
assert_eq "1" "$rc" "runner exits non-zero when a test file reports failures but exits 0"
assert_file_contains "$TEST_TMP/malformed/out.txt" "1 passed, 1 failed" \
    "runner summary counts the failure from the malformed file"

# --- Test: a well-formed passing file leaves the runner green ---
rc=$(_run_runner_over healthy 'echo "ok 1 - passing"
echo "ok 2 - also passing"
exit 0')
assert_eq "0" "$rc" "runner exits zero when every test file passes"

# --- Test: a file that exits non-zero without TAP output still fails ---
# The complementary signal: a crash before any assertion prints nothing to
# count, so the child status has to remain authoritative too.
rc=$(_run_runner_over crashed 'echo "# blew up before asserting anything"
exit 3')
assert_eq "1" "$rc" "runner exits non-zero when a test file crashes with no TAP output"

# --- Test: discovering no test files is a failure, not a clean run ---
mkdir -p "$TEST_TMP/empty"
cp "$RUNNER" "$TEST_TMP/empty/"
empty_rc=0
bash "$TEST_TMP/empty/test_runner.sh" >/dev/null 2>&1 || empty_rc=$?
assert_eq "1" "$empty_rc" "runner exits non-zero when it discovers no test files"

filtered_rc=0
bash "$RUNNER" no-such-test-file-exists >/dev/null 2>&1 || filtered_rc=$?
assert_eq "1" "$filtered_rc" "runner exits non-zero when the filter matches nothing"

# --- Test: the message the distro harness asserts on still exists ---
# tests/distro/test_integration.sh check 5 greps setup.sh's output for
# "domain.name is required" to tell a real config rejection apart from a crash
# before validation. Nothing runs that harness without Vagrant, so this keeps
# the pattern from rotting silently when the message is reworded.
source "$LIB_DIR/03_toml_parser.sh"
source "$LIB_DIR/04_config.sh"

declare -gA CONFIG=()
HEADLESS="false"
CONFIG["domain.name"]=""
_config_apply_defaults
validate_rc=0
validate_err=$(config_validate 2>&1 >/dev/null) || validate_rc=$?
assert_ne "0" "$validate_rc" "config_validate rejects an empty domain.name"
assert_match "domain.name is required" "$validate_err" \
    "config_validate names domain.name as the reason (distro harness greps for this)"

test_report
