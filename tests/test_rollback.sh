#!/usr/bin/env bash
# Tests for lib/25_rollback.sh
# shellcheck disable=SC2034,SC2154
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/25_rollback.sh"

setup_test_tmp

# --- Test: manifest initialization ---
# Use the readonly MATRIX_SETUP_MANIFEST_FILE from constants
CONFIG[install_dir]="$TEST_TMP"

rollback_init_manifest

# MANIFEST_FILE is set by rollback_init_manifest (a mktemp'd path)
_TEST_NUM=$((_TEST_NUM + 1))
if [[ -n "$MANIFEST_FILE" && -f "$MANIFEST_FILE" ]]; then
    echo "ok $_TEST_NUM - manifest file created"
else
    echo "not ok $_TEST_NUM - manifest file created"
    echo "#   MANIFEST_FILE=$MANIFEST_FILE"
fi

# --- Test: snapshot entries are written ---
rollback_snapshot "test-phase" "FILE_CREATED" "/tmp/test-file"
rollback_snapshot "test-phase" "FILE_CREATED" "/tmp/test-file2"

assert_file_contains "$MANIFEST_FILE" "test-phase" "manifest has phase name"
assert_file_contains "$MANIFEST_FILE" "FILE_CREATED" "manifest has action type"
assert_file_contains "$MANIFEST_FILE" "/tmp/test-file" "manifest has action data"

# --- Test: manifest format (pipe-delimited with timestamp) ---
last_line=$(tail -1 "$MANIFEST_FILE")
assert_match '^[0-9]+\|' "$last_line" "manifest entry starts with timestamp"

field_count=$(echo "$last_line" | awk -F'|' '{print NF}')
assert_eq "4" "$field_count" "manifest entry has 4 pipe-delimited fields"

# --- Test: multiple phases tracked ---
rollback_snapshot "phase-a" "SSH_CONFIG" "/etc/ssh/sshd_config.d/99-matrix"
rollback_snapshot "phase-b" "FIREWALL_RULE" "ufw:80/tcp"

assert_file_contains "$MANIFEST_FILE" "phase-a" "phase-a tracked"
assert_file_contains "$MANIFEST_FILE" "phase-b" "phase-b tracked"

# --- Test: file-based rollback action ---
echo "test content" > "$TEST_TMP/removable-file"
rollback_snapshot "cleanup-test" "FILE_CREATED" "$TEST_TMP/removable-file"

assert_file_exists "$TEST_TMP/removable-file" "file exists before rollback"

# Clean up manifest
rm -f "$MANIFEST_FILE"

teardown_test_tmp
test_report
