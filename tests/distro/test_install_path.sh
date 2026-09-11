#!/usr/bin/env bash
# Matrix Stack Setup — Distro Install-Path Test
# Runs the real per-distro install path on a bare VM. Must run as root,
# before anything has pre-installed Podman, so that a wrong package name for
# this distro shows up as a failure here rather than as a silent no-op.
#
# Invoked by tests/distro/Vagrantfile ahead of test_integration.sh.
#
# shellcheck disable=SC2034  # globals below are read by the sourced libs
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
PASSED=0
FAILED=0

log()  { printf '[PREREQ] %s\n' "$*"; }
pass() { log "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { log "FAIL: $1"; FAILED=$((FAILED + 1)); }

if (( EUID != 0 )); then
    log "must run as root (the install functions call the package manager)"
    exit 1
fi

# The libs expect these; HEADLESS makes confirm_prompt take its default, which
# is "yes" for every install prompt on this path.
export NO_COLOR=1
HEADLESS="true"
QUIET="false"
VERBOSE="true"
declare -gA CONFIG=()

# shellcheck source=/dev/null
source "$PROJECT_DIR/lib/00_constants.sh"
# shellcheck source=/dev/null
source "$PROJECT_DIR/lib/01_utils.sh"
# shellcheck source=/dev/null
source "$PROJECT_DIR/lib/02_detect.sh"
# shellcheck source=/dev/null
source "$PROJECT_DIR/lib/05_prerequisites.sh"

detect_os
detect_init_system
log "=== Prerequisite Test on $OS_PRETTY (ID=$OS_ID, family=$OS_FAMILY) ==="

# 1. The distro must be recognised, or every install branch is skipped silently.
if [[ "$OS_FAMILY" != "unknown" ]]; then
    pass "OS_FAMILY resolved to '$OS_FAMILY'"
else
    fail "OS_FAMILY is 'unknown' for ID=$OS_ID — no install branch will run"
fi

# 2. The box must be bare, or this file proves nothing about the install path.
if command -v podman >/dev/null 2>&1; then
    fail "podman is already installed ($(podman --version)); the box is not bare"
else
    pass "podman absent before install"
fi

# 3. Run the real thing.
log "Running prereq_check_all..."
prereq_rc=0
prereq_check_all || prereq_rc=$?
if (( prereq_rc == 0 )); then
    pass "prereq_check_all"
else
    fail "prereq_check_all exited $prereq_rc"
fi

# 4. Podman is installed and meets the Quadlet floor.
detect_podman
if [[ -n "$PODMAN_VERSION" ]]; then
    pass "podman installed ($PODMAN_VERSION)"
    if version_gte "$PODMAN_VERSION" "$MIN_PODMAN_VERSION"; then
        pass "podman $PODMAN_VERSION >= $MIN_PODMAN_VERSION"
    else
        fail "podman $PODMAN_VERSION < $MIN_PODMAN_VERSION — this distro cannot be supported"
    fi
else
    fail "podman still not installed after prereq_check_all"
fi

# 5. Rootless uid/gid mapping. The owning package differs per distro and per
#    release, so this is the assertion that catches a wrong package name.
if command -v newuidmap >/dev/null 2>&1 && command -v newgidmap >/dev/null 2>&1; then
    pass "newuidmap/newgidmap present"
else
    fail "newuidmap/newgidmap missing — rootless Podman will not work"
fi

# 6. A compose tool was found.
detect_compose_command
if [[ -n "$COMPOSE_CMD" ]]; then
    pass "compose tool: $COMPOSE_CMD (networking: $COMPOSE_NETWORKING)"
else
    fail "no compose tool after prereq_check_all"
fi

# 7. The compose tool must be runnable by an unprivileged user: the stack is
#    brought up through run_as_user, not as root. A virtualenv created with a
#    restrictive umask passes every check above and then fails at deploy.
compose_bin="${COMPOSE_CMD%% *}"
if [[ "$compose_bin" == "podman" ]]; then
    pass "compose runs via podman itself; no separate binary to check"
elif su -s /bin/sh -c "$(printf '%q --version' "$compose_bin")" nobody >/dev/null 2>&1; then
    pass "$compose_bin is runnable by an unprivileged user"
else
    fail "$compose_bin is not runnable by an unprivileged user; deploy would fail under run_as_user"
fi

# 8. Supporting tools.
for tool in curl openssl jq; do
    if command -v "$tool" >/dev/null 2>&1; then
        pass "$tool present"
    else
        fail "$tool missing after prereq_check_all"
    fi
done

log "=== Prerequisites: $PASSED passed, $FAILED failed ==="
(( FAILED == 0 ))
