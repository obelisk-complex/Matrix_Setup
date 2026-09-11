#!/usr/bin/env bash
# Tests for setup.sh's command-line surface.
#
# --help and --generate-config are the two things a reader runs before trusting
# the installer with root, and both run before require_root, so they are
# testable directly.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"

setup_test_tmp

for flag in -h --help; do
    rc=0
    out="$(bash "$PROJECT_DIR/setup.sh" "$flag" 2>&1)" || rc=$?
    assert_eq "0" "$rc" "$flag exits 0"
    assert_match "Usage: sudo bash setup.sh" "$out" "$flag prints a usage line"
    for opt in --headless --config --quiet --podman-secrets --generate-config --upgrade --rollback; do
        assert_match "$opt" "$out" "$flag documents $opt"
    done
    # The help used to be `head -17 "$0" | tail -14`, which printed the file's
    # own comment markers, a shellcheck directive and a line of shell.
    assert_no_match "shellcheck" "$out" "$flag prints no shellcheck directive"
    assert_no_match "set -Eeuo" "$out" "$flag prints no source code"
    assert_no_match "^#" "$out" "$flag prints no comment markers"
done

# An unknown option must be rejected, not ignored.
rc=0
out="$(bash "$PROJECT_DIR/setup.sh" --no-such-flag 2>&1)" || rc=$?
assert_ne "0" "$rc" "an unknown option exits non-zero"
assert_match "Unknown option" "$out" "an unknown option is named"

teardown_test_tmp
test_report
