#!/usr/bin/env bash
# Tests for lib/23_media_retention.sh — the media-cleanup script and timer.
#
# The script this phase generates is not run by the installer. It is run later
# by a systemd *user* timer, as the matrix user, in a session that has none of
# the installer's libraries, variables or privileges. So the tests execute the
# generated file as a child process with a stripped environment rather than
# sourcing it: anything it needs that the installer used to provide would show
# up as a runtime failure there and nowhere else.
#
# `podman` and `curl` are stubbed as separate binaries on PATH so that "reached
# the homeserver through the container" and "reached it over a host port" are
# distinguishable. Counting one alone would pass on code that did both.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/23_media_retention.sh"

setup_test_tmp
trap teardown_test_tmp EXIT

# Provided by phases this one does not run.
rollback_snapshot() { :; }

# =====================================================================
# Stub harness
#
# The generated script runs under `env -i`, so the stubs cannot read their
# record files out of the environment: the paths are baked in at stub-creation
# time instead.
# =====================================================================
STUB_BIN="$TEST_TMP/stub_bin"
mkdir -p "$STUB_BIN"

CURL_CALLS="$TEST_TMP/curl.calls"
PODMAN_CALLS="$TEST_TMP/podman.calls"
DF_PCENT_FILE="$TEST_TMP/df.pcent"
: > "$CURL_CALLS"; : > "$PODMAN_CALLS"; printf '40\n' > "$DF_PCENT_FILE"

cat > "$STUB_BIN/curl" << STUB
#!/usr/bin/env bash
# Records a host-side curl. Nothing the timer runs may make one: no homeserver
# port is published to the host, so it could only ever fail to connect.
printf '%s\n' "\$*" >> "$CURL_CALLS"
exit 7   # curl's "failed to connect"
STUB

cat > "$STUB_BIN/podman" << STUB
#!/usr/bin/env bash
# Records a podman invocation, so a container round-trip is visible separately
# from a host-side one.
printf '%s\n' "\$*" >> "$PODMAN_CALLS"
exit 0
STUB

cat > "$STUB_BIN/df" << STUB
#!/usr/bin/env bash
# Answers \`df <dir> --output=pcent\` with the percentage under test.
printf 'Use%%\n %s%%\n' "\$(cat "$DF_PCENT_FILE")"
STUB

cat > "$STUB_BIN/chown" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat > "$STUB_BIN/systemctl" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat > "$STUB_BIN/sudo" << 'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then shift 2; fi
[[ "${1:-}" == "--" ]] && shift
exec "$@"
STUB

chmod +x "$STUB_BIN"/*
PATH="$STUB_BIN:$PATH"

# The real one shells out to getent; the matrix user does not exist here.
FAKE_HOME="$TEST_TMP/home/matrix"
get_user_home() { printf '%s' "$FAKE_HOME"; }

INSTALL_DIR="$TEST_TMP/install"
CLEANUP_SCRIPT="$INSTALL_DIR/scripts/media-cleanup.sh"
PHASE_OUT="$TEST_TMP/phase.out"

# Run the phase from a clean slate. $1 = homeserver type, $2 = federation,
# $3 = retention days. Output goes to a file rather than a command
# substitution: the caller needs the state this leaves behind, and a subshell
# would discard it.
run_phase_fresh() {
    local hs_type="${1:-synapse}" federation="${2:-true}" days="${3:-90}"

    rm -rf "${INSTALL_DIR:?}" "${TEST_TMP:?}/home"
    mkdir -p "$INSTALL_DIR/scripts"

    CONFIG=()
    CONFIG["install_dir"]="$INSTALL_DIR"
    CONFIG["matrix_user"]="matrix"
    CONFIG["domain.name"]="example.com"
    CONFIG["homeserver.type"]="$hs_type"
    CONFIG["federation.enabled"]="$federation"
    CONFIG["media_retention.days"]="$days"

    : > "$CURL_CALLS"; : > "$PODMAN_CALLS"

    media_retention_setup > "$PHASE_OUT" 2>&1 || true
}

# Execute the generated script the way the timer does: as a child process with
# no installer environment at all.
run_cleanup_standalone() {
    : > "$CURL_CALLS"; : > "$PODMAN_CALLS"
    env -i \
        PATH="$STUB_BIN:/usr/bin:/bin" \
        HOME="$FAKE_HOME" \
        "$CLEANUP_SCRIPT" 2>&1
}

call_count() { wc -l < "$1" | tr -d ' '; }

# =====================================================================
# The generated script must not need anything the installer provided
# =====================================================================

run_phase_fresh synapse true 90

# Guard the negative assertions below: "the file does not contain X" is also
# true of a file that was never written.
assert_file_exists "$CLEANUP_SCRIPT" "the phase generates the cleanup script"

script_body=$(cat "$CLEANUP_SCRIPT" 2>/dev/null || true)
assert_ne "" "$script_body" "the generated script is not empty"

assert_no_match 'localhost:8008' "$script_body" \
    "the generated script does not address a host port the stack never publishes"
assert_no_match 'http://' "$script_body" \
    "the generated script makes no HTTP request at all"
assert_no_match '_synapse/admin' "$script_body" \
    "the generated script does not call an admin API it has no token for"
assert_no_match 'admin-token' "$script_body" \
    "the generated script does not read an admin token nothing ever writes"

for fn in run_as_user log_step log_substep log_success template_render; do
    assert_no_match "$fn" "$script_body" \
        "the generated script does not call ${fn}(), which exists only in the installer"
done

# =====================================================================
# Standalone execution
# =====================================================================

mkdir -p "$INSTALL_DIR/data/media"
standalone_out=$(run_cleanup_standalone) || standalone_rc=$?
assert_eq "0" "${standalone_rc:-0}" "the generated script succeeds standalone"
assert_eq "0" "$(call_count "$CURL_CALLS")" \
    "standalone run makes no host-side curl"
assert_eq "0" "$(call_count "$PODMAN_CALLS")" \
    "standalone run needs no container round-trip either"
assert_match "Media check completed" "$standalone_out" \
    "standalone run reports completion"

# =====================================================================
# Disk thresholds
# =====================================================================

printf '95\n' > "$DF_PCENT_FILE"
out=$(run_cleanup_standalone)
assert_match "ALERT" "$out" "95% disk usage raises an ALERT"

printf '85\n' > "$DF_PCENT_FILE"
out=$(run_cleanup_standalone)
assert_match "WARNING: Disk usage" "$out" "85% disk usage raises a WARNING"

printf '40\n' > "$DF_PCENT_FILE"
out=$(run_cleanup_standalone)
assert_no_match "ALERT" "$out" "40% disk usage raises no ALERT"
assert_no_match "WARNING: Disk usage" "$out" "40% disk usage raises no WARNING"

rm -rf "$INSTALL_DIR/data/media"
out=$(run_cleanup_standalone) || true
assert_match "does not exist" "$out" \
    "a missing media directory is reported rather than silently skipped"

# =====================================================================
# Synapse: retention is enforced by the homeserver's own config
#
# templates/configs/homeserver.synapse.yaml.tpl renders
# media_retention.remote_media_lifetime, which Synapse enforces itself. The
# timer must describe that policy, not claim to perform a purge it cannot.
# =====================================================================

run_phase_fresh synapse true 30
mkdir -p "$INSTALL_DIR/data/media"
out=$(run_cleanup_standalone)
assert_match "media_retention" "$out" \
    "synapse: the timer names the config option that does the purging"
assert_match "30 days" "$out" \
    "synapse: the timer reports the configured retention period"

run_phase_fresh synapse false 30
mkdir -p "$INSTALL_DIR/data/media"
out=$(run_cleanup_standalone)
assert_match "ederation" "$out" \
    "synapse without federation: the timer says why there is no remote media cache"

# =====================================================================
# Dendrite: no remote-media retention exists
#
# Dendrite v0.14.1 registers no media-purge admin route (clientapi/routing.go)
# and its MediaAPI config carries no retention option
# (setup/config/config_mediaapi.go). The phase must say so instead of installing
# a timer that silently does nothing.
# =====================================================================

run_phase_fresh dendrite true 30
phase_out=$(cat "$PHASE_OUT")
assert_match "Dendrite" "$phase_out" \
    "dendrite: the installer warns during setup, not only in the journal"
assert_match "no remote-media retention" "$phase_out" \
    "dendrite: the warning names retention as unavailable, not merely configured"

mkdir -p "$INSTALL_DIR/data/media"
out=$(run_cleanup_standalone)
assert_no_match "30 days" "$out" \
    "dendrite: the timer does not claim a retention period it cannot enforce"
assert_match "Dendrite" "$out" \
    "dendrite: the timer says retention is unavailable on this homeserver"
assert_eq "0" "$(call_count "$CURL_CALLS")" "dendrite: no host-side curl"
assert_eq "0" "$(call_count "$PODMAN_CALLS")" "dendrite: no container round-trip"

# =====================================================================
# Units
# =====================================================================

run_phase_fresh synapse true 90
UNIT="$FAKE_HOME/.config/systemd/user/matrix-media-cleanup.service"
assert_file_exists "$UNIT" "the service unit is installed"
assert_file_contains "$UNIT" "ExecStart=$CLEANUP_SCRIPT" \
    "the unit runs the script the phase generated"
assert_file_exists "$FAKE_HOME/.config/systemd/user/matrix-media-cleanup.timer" \
    "the timer unit is installed"

mode=$(stat -c '%a' "$CLEANUP_SCRIPT")
assert_eq "750" "$mode" "the generated script is not world-readable"

# =====================================================================
# The phase does not depend on an earlier one having made its directory
#
# $install_dir/scripts happens to exist because backup_setup runs first and
# creates it. Nothing states that ordering, so this phase makes its own.
# =====================================================================

rm -rf "${INSTALL_DIR:?}" "${TEST_TMP:?}/home"
mkdir -p "$INSTALL_DIR"
CONFIG=()
CONFIG["install_dir"]="$INSTALL_DIR"
CONFIG["matrix_user"]="matrix"
CONFIG["domain.name"]="example.com"
CONFIG["homeserver.type"]="synapse"
media_retention_setup > "$PHASE_OUT" 2>&1 || true
assert_file_exists "$CLEANUP_SCRIPT" \
    "the phase creates its scripts directory rather than inheriting one"

test_report
