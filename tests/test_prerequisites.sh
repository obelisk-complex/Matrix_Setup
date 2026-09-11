#!/usr/bin/env bash
# Tests for lib/05_prerequisites.sh — per-distro package selection and the
# messages shown when the Podman floor cannot be met.
#
# The package managers are replaced with recording stubs on PATH, so the
# install branches run for real and the exact argv is asserted. Nothing is
# installed and no network is touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/02_detect.sh"
source "$LIB_DIR/05_prerequisites.sh"

setup_test_tmp

STUB_BIN="$TEST_TMP/stub_bin"
CALL_LOG="$TEST_TMP/calls.log"
mkdir -p "$STUB_BIN"

for pm in apt-get dnf yum pacman zypper pip3 systemctl; do
    cat > "$STUB_BIN/$pm" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$pm" "\$*" >> "$CALL_LOG"
exit 0
STUB
    chmod +x "$STUB_BIN/$pm"
done

# Runs one install branch with the stubs in front of PATH and prints what the
# branch invoked. Empty output means the branch did not run at all, which an
# assertion on package names would otherwise read as "did not ask for uidmap".
_calls_for() {
    local family="$1" func="$2"
    : > "$CALL_LOG"
    OS_FAMILY="$family" OS_ID="$family" PATH="$STUB_BIN:$PATH" "$func" >/dev/null 2>&1 || true
    cat "$CALL_LOG"
}

# --- Test: the stubs are actually reached ---
podman_debian="$(_calls_for debian _install_podman)"
assert_match 'apt-get install' "$podman_debian" "debian branch reaches the package manager"

# --- Test: `uidmap` is a Debian package name and must not leak elsewhere ---
# Verified absent from CentOS Stream 9 BaseOS/AppStream and from openSUSE Leap
# 15.6 / 16.0 / 16.1 / Tumbleweed OSS. dnf and zypper abort the whole
# transaction on an unknown package, so a stray `uidmap` means Podman never
# gets installed at all.
assert_match 'uidmap' "$podman_debian" "debian installs uidmap (correct there)"

podman_rhel="$(_calls_for rhel _install_podman)"
assert_ne "" "$podman_rhel" "rhel branch reaches the package manager"
assert_no_match '(^| )uidmap( |$)' "$podman_rhel" "rhel branch does not request uidmap"
assert_match 'shadow-utils' "$podman_rhel" "rhel branch requests shadow-utils"
assert_match 'podman' "$podman_rhel" "rhel branch requests podman"

podman_suse="$(_calls_for suse _install_podman)"
assert_ne "" "$podman_suse" "suse branch reaches the package manager"
assert_no_match '(^| )uidmap( |$)' "$podman_suse" "suse branch does not request uidmap"
assert_match 'zypper' "$podman_suse" "suse branch uses zypper"
assert_match 'podman' "$podman_suse" "suse branch requests podman"
assert_match 'slirp4netns' "$podman_suse" "suse branch requests slirp4netns"

# --- Test: rootless uid/gid mapping tools on openSUSE ---
# newuidmap/newgidmap ship in `shadow` on Leap 15.6 and 16.0 but were split out
# into shadow-pw-mgmt (Leap 16.1) / account-utils (Tumbleweed). Asking for the
# binary lets zypper resolve whichever package owns it on this release.
tools_suse="$(
    : > "$CALL_LOG"
    OS_FAMILY="suse" PATH="$STUB_BIN:$PATH" \
        CONFIRM_DEFAULT_YES=1 _install_rootless_uidmap >/dev/null 2>&1 || true
    cat "$CALL_LOG"
)"
assert_ne "" "$tools_suse" "suse uidmap branch reaches zypper"
assert_match 'newuidmap' "$tools_suse" "suse asks zypper for the newuidmap binary"
assert_no_match '(^| )uidmap( |$)' "$tools_suse" "suse uidmap branch does not request the uidmap package"

tools_rhel="$(
    : > "$CALL_LOG"
    OS_FAMILY="rhel" PATH="$STUB_BIN:$PATH" _install_rootless_uidmap >/dev/null 2>&1 || true
    cat "$CALL_LOG"
)"
assert_match 'shadow-utils' "$tools_rhel" "rhel uidmap branch requests shadow-utils"

# --- Test: zypper is driven non-interactively ---
# `zypper install -y` is a newer alias; `--non-interactive` works on every
# supported Leap and on Tumbleweed.
assert_match 'non-interactive' "$podman_suse" "suse install is non-interactive"

# --- Test: the "too old" message is actionable ---
# It has to name what was found, what is needed and what the user can do;
# "Please upgrade manually" on its own tells them nothing.
too_old_out="$(
    PATH="$STUB_BIN:$PATH" bash -c '
        source "'"$LIB_DIR"'/00_constants.sh"
        source "'"$LIB_DIR"'/01_utils.sh"
        source "'"$LIB_DIR"'/02_detect.sh"
        source "'"$LIB_DIR"'/05_prerequisites.sh"
        OS_PRETTY="Fixture Linux 1.0"
        _podman_too_old_message "4.3.1"
    ' 2>&1 || true
)"
assert_match '4\.3\.1' "$too_old_out" "too-old message names the detected version"
assert_match '4\.7\.0' "$too_old_out" "too-old message names the required version"
assert_match '[Qq]uadlet' "$too_old_out" "too-old message names the Quadlet requirement"
assert_match 'secret' "$too_old_out" "too-old message names the secrets requirement"
assert_match 'Fixture Linux 1.0' "$too_old_out" "too-old message names the detected OS"
assert_match 'README' "$too_old_out" "too-old message points at the supported platform list"

# --- podman-compose venv fallback ---
# Every pip path must go into a dedicated virtualenv: PEP 668 distributions
# refuse a system-wide install outright, and --break-system-packages is exactly
# the breakage the marker exists to prevent.
#
# python3 is stubbed to fake `-m venv`, so no virtualenv is built and nothing
# is written outside TEST_TMP. The venv root is redirected with
# MATRIX_SETUP_VENV_ROOT, which only exists for this.
VENV_ROOT="$TEST_TMP/venvroot"
VENV_DIR="$VENV_ROOT/podman-compose"
PY_STUB="$TEST_TMP/py_stub"
mkdir -p "$PY_STUB"

cat > "$PY_STUB/python3" <<STUB
#!/usr/bin/env bash
printf 'python3 %s\n' "\$*" >> "$CALL_LOG"
# The >= 3.8 probe
[[ "\${1:-}" == "-c" ]] && exit 0
if [[ "\${1:-}" == "-m" && "\${2:-}" == "venv" ]]; then
    [[ "\${3:-}" == "--help" ]] && exit 0
    d="\${3:-}"
    mkdir -p "\$d/bin"
    # A real venv's pip lives inside the venv; record which one was used.
    cat > "\$d/bin/pip" <<'INNER'
#!/usr/bin/env bash
printf 'pip(%s) %s\n' "\$0" "\$*" >> "__CALL_LOG__"
# `pip install` is what produces the entry point
for a in "\$@"; do
    if [[ "\$a" == podman-compose==* ]]; then
        printf '#!/bin/sh\necho podman-compose \${a#*==}\n' > "\$(dirname "\$0")/podman-compose"
        chmod +x "\$(dirname "\$0")/podman-compose"
    fi
done
exit 0
INNER
    sed -i "s|__CALL_LOG__|$CALL_LOG|" "\$d/bin/pip"
    chmod +x "\$d/bin/pip"
    exit 0
fi
exit 0
STUB
chmod +x "$PY_STUB/python3"

_venv_install() {
    : > "$CALL_LOG"
    local family="${1:-suse}" umask_val="${2:-022}"
    rm -rf "$VENV_ROOT"
    MATRIX_SETUP_VENV_ROOT="$VENV_ROOT" PATH="$PY_STUB:$STUB_BIN:$PATH" \
    bash -c '
        umask '"$umask_val"'
        source "'"$LIB_DIR"'/00_constants.sh"
        source "'"$LIB_DIR"'/01_utils.sh"
        source "'"$LIB_DIR"'/02_detect.sh"
        source "'"$LIB_DIR"'/05_prerequisites.sh"
        OS_FAMILY="'"$family"'"
        HEADLESS="true"
        _pip_install_compose
    ' >/dev/null 2>&1
}

venv_rc=0
_venv_install suse || venv_rc=$?
venv_calls="$(cat "$CALL_LOG")"

assert_eq "0" "$venv_rc" "_pip_install_compose succeeds"
assert_match "venv $VENV_DIR" "$venv_calls" "a virtualenv is created at the configured path"
assert_match 'podman-compose==1\.3\.0' "$venv_calls" "the pinned version is what gets installed"
assert_match "pip\($VENV_DIR/bin/pip\)" "$venv_calls" "the venv's own pip is used, not the system pip3"
assert_file_exists "$VENV_DIR/bin/podman-compose" "the entry point exists after install"

# Created by root, executed by the unprivileged matrix user via run_as_user.
# A restrictive root umask would otherwise leave this 0700 and the failure
# would surface at deploy time, not here.
_venv_install suse 077
assert_true "venv dir is traversable by other" test -x "$VENV_DIR"
assert_true "venv dir is readable by other" bash -c "[[ \$(stat -c '%a' '$VENV_DIR') =~ [0-9][0-9]?[157]\$ ]]"
assert_true "entry point is executable by other" bash -c "[[ \$(stat -c '%a' '$VENV_DIR/bin/podman-compose') =~ [157]\$ ]]"
assert_eq "$(id -un)" "$(stat -c '%U' "$VENV_DIR")" \
    "venv stays owned by the installing user (root in production)"

# --- Test: no system-wide pip install survives anywhere in the file ---
prereq_src="$LIB_DIR/05_prerequisites.sh"
assert_no_match 'break-system-packages' "$(cat "$prereq_src")" \
    "--break-system-packages is not used"
assert_no_match 'pip3 install' "$(cat "$prereq_src")" \
    "no bare 'pip3 install' call site remains"
assert_eq "1" "$(grep -c 'podman-compose==' "$prereq_src")" \
    "exactly one podman-compose install call site"
assert_eq "1.3.0" "$PODMAN_COMPOSE_VERSION" "the pin is 1.3.0"
# Handing the venv to the matrix user would let it rewrite the code it runs.
# Matched per line: bash's =~ lets `.` span newlines, so a whole-file pattern
# with `.*` would join an unrelated chown to an unrelated mention of the venv.
assert_eq "0" "$(grep -c 'chown.*PODMAN_COMPOSE_VENV' "$prereq_src" || true)" \
    "the venv is not chowned away from the installing user"

# --- Test: the Arch branches route through the pinned venv helper ---
# They used to call `pip3 install podman-compose 2>/dev/null || true`:
# unpinned, as root, failure swallowed.
assert_no_match 'pip3' "$(cat "$prereq_src")" "no pip3 anywhere in the file"
arch_podman="$(sed -n '/^_install_podman/,/^}/p' "$prereq_src" | sed -n '/^ *arch)/,/^ *;;/p')"
arch_compose="$(sed -n '/^_install_compose/,/^}/p' "$prereq_src" | sed -n '/^ *arch)/,/^ *;;/p')"
assert_match '_pip_install_compose' "$arch_podman" \
    "the arch branch of _install_podman calls _pip_install_compose"
assert_match '_pip_install_compose' "$arch_compose" \
    "the arch branch of _install_compose calls _pip_install_compose"

# --- Test: detection finds the venv, and finds it by absolute path ---
# run_as_user switches to the matrix user, whose PATH does not include the
# venv, and systemd needs an absolute ExecStart. A bare name would install
# fine and then be invisible.
detect_out="$(
    MATRIX_SETUP_VENV_ROOT="$VENV_ROOT" PATH="$STUB_BIN:$PATH" bash -c '
        source "'"$LIB_DIR"'/00_constants.sh"
        source "'"$LIB_DIR"'/01_utils.sh"
        source "'"$LIB_DIR"'/02_detect.sh"
        # No built-in `podman compose` on this box.
        podman() { return 1; }
        detect_compose_command
        printf "%s|%s\n" "$COMPOSE_CMD" "$COMPOSE_NETWORKING"
    ' 2>/dev/null
)"
assert_eq "$VENV_DIR/bin/podman-compose|pod" "$detect_out" \
    "detect_compose_command returns the venv binary by absolute path"

# --- Test: a venv that installs but does not run is a failure, not a pass ---
broken_rc=0
MATRIX_SETUP_VENV_ROOT="$TEST_TMP/emptyvenv" PATH="$STUB_BIN:$PATH" bash -c '
    source "'"$LIB_DIR"'/00_constants.sh"
    source "'"$LIB_DIR"'/01_utils.sh"
    source "'"$LIB_DIR"'/02_detect.sh"
    source "'"$LIB_DIR"'/05_prerequisites.sh"
    OS_FAMILY="suse"
    HEADLESS="true"
    # venv creation "succeeds" but produces no entry point.
    python3() { [[ "${1:-}" == "-c" ]] && return 0; mkdir -p "$PODMAN_COMPOSE_VENV/bin"; return 0; }
    _pip_install_compose
' >/dev/null 2>&1 || broken_rc=$?
assert_ne "0" "$broken_rc" "a venv with no working entry point is reported as a failure"

# --- Test: venv module availability per distro ---
# Debian and Ubuntu split it into python3-venv; the rhel, arch and suse
# families ship venv and ensurepip with the interpreter itself.
venv_pkg_debian="$(
    : > "$CALL_LOG"
    OS_FAMILY="debian" PATH="$STUB_BIN:$PATH" _install_venv_module >/dev/null 2>&1 || true
    cat "$CALL_LOG"
)"
assert_match 'python3-venv' "$venv_pkg_debian" "debian installs python3-venv"

# --- Test: a still-missing newuidmap is fatal, not a warning ---
# Rootless Podman cannot map subordinate uids without these, and every service
# in the stack runs rootless. Carrying on produces containers that fail to
# start much later, with nothing pointing back here.
# _check_tools calls exit, so it runs in a child shell.
uidmap_rc=0
uidmap_out="$(
    PATH="$STUB_BIN:$PATH" bash -c '
        source "'"$LIB_DIR"'/00_constants.sh"
        source "'"$LIB_DIR"'/01_utils.sh"
        source "'"$LIB_DIR"'/02_detect.sh"
        source "'"$LIB_DIR"'/05_prerequisites.sh"
        OS_FAMILY="suse"
        HEADLESS="true"
        SYSTEM_RAM_MB=4096
        DISK_FREE_GB=50
        # The install runs (zypper is stubbed and "succeeds") but the binaries
        # are still not there afterwards, which is what a wrong package name
        # looks like on a real box.
        check_command() {
            case "$1" in
                newuidmap|newgidmap) return 1 ;;
                *) command -v "$1" >/dev/null 2>&1 ;;
            esac
        }
        _check_tools
    ' 2>&1
)" || uidmap_rc=$?
assert_eq "$E_PREREQ" "$uidmap_rc" "_check_tools exits E_PREREQ when newuidmap is still missing"
assert_match 'newuidmap' "$uidmap_out" "the failure names newuidmap"
assert_match 'rootless' "$uidmap_out" "the failure says why it matters"

# --- Test: documented platforms match the Podman floor ---
readme="$PROJECT_DIR/README.md"
assert_file_exists "$readme" "README.md present"
readme_reqs="$(sed -n '/^## Requirements/,/^## Quick Start/p' "$readme")"
# The supported-platform table, distinct from prose about excluded releases.
readme_table="$(grep -E '^ *\| ' <<< "$readme_reqs" || true)"

assert_ne "" "$readme_table" "README requirements section has a platform table"
assert_no_match '22\.04' "$readme_table" "platform table omits Ubuntu 22.04 (podman 3.4.4)"
assert_no_match 'Debian 12' "$readme_table" "platform table omits Debian 12 (podman 4.3.1)"
assert_match 'Ubuntu 24\.04' "$readme_table" "platform table lists Ubuntu 24.04"
assert_match 'Debian 13' "$readme_table" "platform table lists Debian 13"
assert_match 'openSUSE Leap' "$readme_table" "platform table lists openSUSE Leap"
assert_match 'openSUSE Tumbleweed' "$readme_table" "platform table lists openSUSE Tumbleweed"

# The dropped releases must be named as excluded, not silently omitted:
# someone on 22.04 needs to be told why, not left to guess.
assert_match 'Ubuntu 22\.04.*not' "$(tr '\n' ' ' <<< "$readme_reqs")" \
    "README names Ubuntu 22.04 as unsupported"
assert_match 'Debian 12.*not' "$(tr '\n' ' ' <<< "$readme_reqs")" \
    "README names Debian 12 as unsupported"
assert_match '4\.7\.0' "$readme_reqs" "README states the Podman 4.7.0 floor"
assert_match '[Qq]uadlet' "$readme_reqs" "README names the Quadlet requirement"
assert_match 'showsecret|secret inspect' "$readme_reqs" "README says what 4.7.0 buys over 4.4.0"

# --- Test: the floor itself ---
# 4.4.0 gives Quadlet; --podman-secrets additionally needs
# `podman secret inspect --showsecret`, introduced in 4.7.0. One floor covers
# both, so nothing between 4.4.0 and 4.7.0 may be accepted.
assert_eq "4.7.0" "$MIN_PODMAN_VERSION" "MIN_PODMAN_VERSION is 4.7.0"
assert_false "4.4.0 (Quadlet only) rejected"  version_gte "4.4.0" "$MIN_PODMAN_VERSION"
assert_false "4.5.0 (secret exists) rejected" version_gte "4.5.0" "$MIN_PODMAN_VERSION"
assert_false "4.6.0 rejected"                 version_gte "4.6.0" "$MIN_PODMAN_VERSION"
assert_true  "4.7.0 accepted"                 version_gte "4.7.0" "$MIN_PODMAN_VERSION"
assert_true  "4.8.3 accepted"                 version_gte "4.8.3" "$MIN_PODMAN_VERSION"
assert_true  "5.0.0 accepted"                 version_gte "5.0.0" "$MIN_PODMAN_VERSION"

teardown_test_tmp
test_report
