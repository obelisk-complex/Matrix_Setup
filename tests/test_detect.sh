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

# --- Test: OS family mapping from /etc/os-release ID values ---
# Fed from fixtures rather than the host so the whole matrix is exercised on
# any machine; the real ID strings are the ones each distro ships.
_family_for_id() {
    local id="$1" version="${2:-}"
    printf 'ID=%s\nVERSION_ID="%s"\nPRETTY_NAME="fixture %s"\n' \
        "$id" "$version" "$id" > "$TEST_TMP/os-release"
    OS_RELEASE_FILE="$TEST_TMP/os-release" detect_os 2>/dev/null
    printf '%s' "$OS_FAMILY"
}

assert_eq "suse"    "$(_family_for_id opensuse-leap 15.6)"    "opensuse-leap -> suse"
assert_eq "suse"    "$(_family_for_id opensuse-tumbleweed)"   "opensuse-tumbleweed -> suse"
assert_eq "suse"    "$(_family_for_id sles 15.6)"             "sles -> suse"
assert_eq "debian"  "$(_family_for_id ubuntu 24.04)"          "ubuntu -> debian"
assert_eq "debian"  "$(_family_for_id debian 13)"             "debian -> debian"
assert_eq "rhel"    "$(_family_for_id fedora 42)"             "fedora -> rhel"
assert_eq "rhel"    "$(_family_for_id centos 9)"              "centos -> rhel"
assert_eq "arch"    "$(_family_for_id arch)"                  "arch -> arch"
assert_eq "unknown" "$(_family_for_id void)"                  "unrecognised ID -> unknown"

# ID and VERSION_ID must survive into the globals the installer branches on.
_family_for_id opensuse-leap 15.6 >/dev/null
assert_eq "opensuse-leap" "$OS_ID" "OS_ID preserved for opensuse-leap"
assert_eq "15.6" "$OS_VERSION" "OS_VERSION preserved for opensuse-leap"

# A missing os-release must not leave stale values from a previous detect_os.
OS_RELEASE_FILE="$TEST_TMP/does-not-exist" detect_os 2>/dev/null
assert_eq "unknown" "$OS_ID" "absent os-release -> OS_ID unknown"
assert_eq "unknown" "$OS_FAMILY" "absent os-release -> OS_FAMILY unknown"

# --- Test: the floor against the versions each supported distro ships ---
# Every release listed in README.md's Requirements table must clear the floor;
# the versions below come from each distribution's own repository metadata.
assert_false "3.4.4 (Ubuntu 22.04) rejected"           version_gte "3.4.4" "$MIN_PODMAN_VERSION"
assert_false "4.3.1 (Debian 12) rejected"              version_gte "4.3.1" "$MIN_PODMAN_VERSION"
assert_true  "4.8.3 (openSUSE Leap 15.6) accepted"     version_gte "4.8.3" "$MIN_PODMAN_VERSION"
assert_true  "4.9.3 (Ubuntu 24.04) accepted"           version_gte "4.9.3" "$MIN_PODMAN_VERSION"
assert_true  "5.4.2 (Debian 13, Leap 16.0) accepted"   version_gte "5.4.2" "$MIN_PODMAN_VERSION"
assert_true  "5.6.2 (Fedora 43) accepted"              version_gte "5.6.2" "$MIN_PODMAN_VERSION"
assert_true  "5.8.1 (Fedora 44) accepted"              version_gte "5.8.1" "$MIN_PODMAN_VERSION"
assert_true  "5.8.2 (Leap 16.1, RHEL 9 rebuilds) accepted" version_gte "5.8.2" "$MIN_PODMAN_VERSION"
assert_true  "5.8.5 (CentOS Stream 9) accepted"        version_gte "5.8.5" "$MIN_PODMAN_VERSION"
assert_true  "6.0.2 (openSUSE Tumbleweed) accepted"    version_gte "6.0.2" "$MIN_PODMAN_VERSION"
assert_true  "6.1.1 (Arch) accepted"                   version_gte "6.1.1" "$MIN_PODMAN_VERSION"

# --- Test: RAM detection returns a number ---
detected_ram=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}') || detected_ram=""
assert_match '^[0-9]+$' "${detected_ram:-}" "RAM detection returns number: ${detected_ram:-unknown}MB"

# --- Test: architecture detection ---
arch=$(uname -m)
assert_ne "" "$arch" "architecture detected"
assert_match '^(x86_64|aarch64|armv7l|arm64|s390x|ppc64le|riscv64|i686)$' "$arch" "known architecture"

teardown_test_tmp
test_report
