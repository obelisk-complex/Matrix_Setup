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
assert_eq "rhel"    "$(_family_for_id fedora 43)"             "fedora -> rhel"
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

# --- Test: the supported-release list stated in the docs ---
# Nothing under lib/ encodes a per-distro release floor: the only version gate
# is MIN_PODMAN_VERSION against the podman actually installed (lib/05_prerequisites.sh).
# The supported-release list therefore exists only in README.md and the spec,
# which makes those two files the thing to pin.
#
# Fedora's minimum is 43. Fedora 41 (EOL 2025-12-15) and 42 (EOL 2026-05-27)
# ship podman 5.2.5 and 5.4.1, which clear the floor, but both are past end of
# life and receive no security updates — dates from endoflife.date/api/fedora.json,
# podman versions from the releases/<N>/Everything/x86_64/os repodata each
# release shipped with.
README_FILE="$PROJECT_DIR/README.md"
SPEC_FILE="$PROJECT_DIR/specs/2026-04-06-matrix-stack-setup-script.md"

assert_file_exists "$README_FILE" "README.md is present to be checked"
assert_file_exists "$SPEC_FILE" "the spec is present to be checked"

# The claim of support lives in exactly two places: the README requirements
# table and the spec's NFR-01 row. Releases named anywhere else — the "not
# supported" paragraph under the README table — are deliberate exclusions, so
# the scan is scoped to the two lists rather than the whole file.
#
# Both helpers emit a sentinel instead of the empty string when the list is
# absent, and each list is checked by a matching pair: the assert_match proves
# the text was found, which is what stops the paired assert_no_match from
# passing on nothing.
_readme_distro_table() {
    [[ -f "$README_FILE" ]] || { printf 'README-MISSING'; return 0; }
    local rows
    rows=$(grep -E '^[[:space:]]*\| (Ubuntu|Debian|Fedora|CentOS|Arch|openSUSE)' "$README_FILE") \
        || { printf 'TABLE-EMPTY'; return 0; }
    printf '%s\n' "$rows"
}

_spec_nfr01_row() {
    [[ -f "$SPEC_FILE" ]] || { printf 'SPEC-MISSING'; return 0; }
    local row
    row=$(grep -E '^\| NFR-01 ' "$SPEC_FILE") || { printf 'NFR01-MISSING'; return 0; }
    printf '%s\n' "$row"
}

readme_table="$(_readme_distro_table)"
spec_nfr01="$(_spec_nfr01_row)"

assert_match 'Fedora 43 or newer' "$readme_table" \
    "README requirements table gives Fedora 43 as the minimum"
assert_no_match 'Fedora (39|40|41|42)' "$readme_table" \
    "README requirements table lists no Fedora release below 43"
assert_match 'Fedora 43\+' "$spec_nfr01" \
    "spec NFR-01 gives Fedora 43+ as the supported range"
# The NFR-01 row states its exclusions inline ("... are excluded by NFR-02"),
# so only the "<release>+" supported-range form counts as a claim of support.
assert_no_match 'Fedora (39|40|41|42)\+' "$spec_nfr01" \
    "spec NFR-01 claims no Fedora release below 43 as supported"

# --- Test: RAM detection returns a number ---
detected_ram=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}') || detected_ram=""
assert_match '^[0-9]+$' "${detected_ram:-}" "RAM detection returns number: ${detected_ram:-unknown}MB"

# --- Test: architecture detection ---
arch=$(uname -m)
assert_ne "" "$arch" "architecture detected"
assert_match '^(x86_64|aarch64|armv7l|arm64|s390x|ppc64le|riscv64|i686)$' "$arch" "known architecture"

teardown_test_tmp
test_report
