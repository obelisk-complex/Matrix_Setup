#!/usr/bin/env bash
# Tests for lib/24_report.sh — the post-install report.
#
# The report is what the operator reads instead of watching the install, so a
# component that did not start has to appear here rather than being implied by
# a line about ports.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/24_report.sh"

setup_test_tmp

rollback_snapshot() { :; }

# report_generate reads this array, which lib/16_bridges.sh declares; setup.sh
# sources every module, this test sources one.
declare -ga BRIDGES_ENABLED=()

INSTALL_DIR="$TEST_TMP/install"
mkdir -p "$INSTALL_DIR"
REPORT="$INSTALL_DIR/post-install-report.txt"

generate_report() {
    declare -gA CONFIG=()
    CONFIG["domain.name"]="example.com"
    CONFIG["install_dir"]="$INSTALL_DIR"
    CONFIG["homeserver.type"]="synapse"
    CONFIG["coturn.enabled"]="true"
    [[ -n "${1:-}" ]] && CONFIG["deploy.coturn_result"]="$1"
    rm -f "$REPORT"
    report_generate >/dev/null 2>&1
}

# --- Test: a coturn that failed to start is visible in the report ---
generate_report "failed"
assert_file_exists "$REPORT" "the report is written"
assert_file_contains "$REPORT" "Coturn:         failed" \
    "a coturn that did not start is reported as failed"

generate_report "started"
assert_file_contains "$REPORT" "Coturn:         started" \
    "a coturn that started is reported as started"

# A deploy that never reached the coturn step must not read as a success.
generate_report
assert_file_contains "$REPORT" "Coturn:         not started" \
    "an unrecorded coturn is reported as not started, not as running"

# --- Test: coturn lines are omitted entirely when coturn is disabled ---
declare -gA CONFIG=()
CONFIG["domain.name"]="example.com"
CONFIG["install_dir"]="$INSTALL_DIR"
CONFIG["coturn.enabled"]="false"
rm -f "$REPORT"
report_generate >/dev/null 2>&1
assert_file_exists "$REPORT" "the report is written with coturn disabled"
assert_false "no coturn status is reported when coturn is disabled" \
    grep -q 'Coturn:' "$REPORT"

teardown_test_tmp
test_report
