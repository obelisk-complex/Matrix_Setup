#!/usr/bin/env bash
# Tests for lib/02_detect.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/02_detect.sh"

setup_test_tmp

# --- Test: detect with mock /etc/os-release ---
cat > "$TEST_TMP/os-release-ubuntu" << 'EOF'
ID=ubuntu
ID_LIKE=debian
VERSION_ID="24.04"
VERSION_CODENAME=noble
NAME="Ubuntu"
EOF

cat > "$TEST_TMP/os-release-fedora" << 'EOF'
ID=fedora
VERSION_ID="40"
NAME="Fedora Linux"
EOF

cat > "$TEST_TMP/os-release-arch" << 'EOF'
ID=arch
NAME="Arch Linux"
EOF

# Test current system detection via detect_os
if declare -f detect_os &>/dev/null; then
    detect_os 2>/dev/null || true
    assert_ne "" "${OS_ID:-}" "OS ID detected via detect_os"
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
detected_ram=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}') || detected_ram="0"
_TEST_NUM=$((_TEST_NUM + 1))
if [[ "$detected_ram" =~ ^[0-9]+$ ]]; then
    echo "ok $_TEST_NUM - RAM detection returns number: ${detected_ram}MB"
else
    echo "not ok $_TEST_NUM - RAM detection failed"
fi

# --- Test: architecture detection ---
arch=$(uname -m)
assert_ne "" "$arch" "architecture detected"
assert_match '^(x86_64|aarch64|armv7l|s390x|ppc64le)$' "$arch" "known architecture"

teardown_test_tmp
test_report
