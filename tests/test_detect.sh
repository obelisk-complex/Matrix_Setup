#!/usr/bin/env bash
# Tests for lib/02_detect.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/02_detect.sh"

setup_test_tmp

# --- Test: detect_os sets OS_ID on current system ---
if declare -f detect_os &>/dev/null; then
    detect_os 2>/dev/null || true
    assert_ne "" "${OS_ID:-}" "OS_ID detected via detect_os"
else
    skip_test "detect_os function not available"
fi

# --- Test: version comparison ---
source "$LIB_DIR/01_utils.sh"

assert_true "version_gte 5.0.0 >= 4.4.0" version_gte "5.0.0" "4.4.0"
assert_true "version_gte 4.4.0 >= 4.4.0" version_gte "4.4.0" "4.4.0"
assert_false "version_gte 4.3.9 < 4.4.0" version_gte "4.3.9" "4.4.0"
assert_true "version_gte 5.2.1 >= 5.0.0" version_gte "5.2.1" "5.0.0"
assert_true "version_gte 16 >= 13" version_gte "16" "13"
assert_false "version_gte 12 < 13" version_gte "12" "13"

# --- Test: RAM detection returns a number ---
detected_ram=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}') || detected_ram=""
assert_match '^[0-9]+$' "${detected_ram:-}" "RAM detection returns number: ${detected_ram:-unknown}MB"

# --- Test: architecture detection ---
arch=$(uname -m)
assert_ne "" "$arch" "architecture detected"
assert_match '^(x86_64|aarch64|armv7l|arm64|s390x|ppc64le|riscv64|i686)$' "$arch" "known architecture"

teardown_test_tmp
test_report
