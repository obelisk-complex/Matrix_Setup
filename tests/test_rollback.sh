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
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
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

# =====================================================================
# Reachability from setup.sh's entry points.
#
# Everything above this line drives the manifest engine in-process, with
# MANIFEST_FILE already in memory. The tests below cover the part that was
# broken: finding the manifest again from setup.sh's traps and from a
# separate --rollback process, where MANIFEST_FILE is empty.
#
# Keep the fallback directory inside the sandbox: rollback actions delete
# files, so no test here may reach a real /tmp/.rollback-manifest.
# =====================================================================
mkdir -p "$TEST_TMP/tmpfallback"
export TMPDIR="$TEST_TMP/tmpfallback"

# --- A dangling pointer (manifest deleted, as just happened above) is not a
#     manifest ---
CONFIG[install_dir]="$TEST_TMP"
MANIFEST_FILE=""
assert_false "guard is false when the pointer's manifest is gone" rollback_resolve_manifest

# --- Fixed-name pointer alongside the unpredictable manifest ---
RB_DIR="$TEST_TMP/reach"
mkdir -p "$RB_DIR"
CONFIG[install_dir]="$RB_DIR"
MANIFEST_FILE=""
rollback_init_manifest
RB_MANIFEST="$MANIFEST_FILE"
RB_POINTER="$RB_DIR/$MATRIX_SETUP_MANIFEST_FILE"

assert_file_exists "$RB_POINTER" "pointer created at the fixed manifest path"
assert_eq "$RB_MANIFEST" "$(cat "$RB_POINTER")" "pointer records the mktemp'd manifest path"
assert_ne "$RB_POINTER" "$RB_MANIFEST" "manifest keeps its unpredictable mktemp name"
assert_eq "600" "$(stat -c '%a' "$RB_MANIFEST")" "manifest is still mode 0600"

# --- The guard finds it again with nothing in memory ---
MANIFEST_FILE=""
assert_true "guard resolves the manifest via the pointer" rollback_resolve_manifest
assert_eq "$RB_MANIFEST" "$MANIFEST_FILE" "guard sets MANIFEST_FILE to the recorded path"

# --- A symlink planted at the fixed path is refused, not followed. The link
#     target is a well-formed pointer, so only the symlink check can reject
#     it: rollback would otherwise delete whatever the planter chose. ---
SYM_DIR="$TEST_TMP/symlink"
mkdir -p "$SYM_DIR"
printf '%s\n' "$RB_MANIFEST" > "$TEST_TMP/planted-pointer"
ln -s "$TEST_TMP/planted-pointer" "$SYM_DIR/$MATRIX_SETUP_MANIFEST_FILE"
CONFIG[install_dir]="$SYM_DIR"
MANIFEST_FILE=""
assert_false "guard refuses a symlinked pointer" rollback_resolve_manifest

# --- ERR-trap guard body: headless prints the recovery command ---
CONFIG[install_dir]="$RB_DIR"
MANIFEST_FILE=""
HEADLESS="true"
trap_out=$(rollback_on_failure 2>&1)
assert_match "--rollback" "$trap_out" "ERR-trap guard prints the --rollback recovery hint"

CONFIG[install_dir]="$SYM_DIR"
MANIFEST_FILE=""
trap_out=$(rollback_on_failure 2>&1)
assert_no_match "--rollback" "$trap_out" "ERR-trap guard stays quiet with no manifest"

# --- ERR-trap guard body: an interactive 'yes' actually rolls back ---
CONFIG[install_dir]="$RB_DIR"
MANIFEST_FILE=""
rollback_resolve_manifest || true
touch "$RB_DIR/created-by-setup"
rollback_snapshot "deploy" "FILE_CREATED" "$RB_DIR/created-by-setup"

MANIFEST_FILE=""
HEADLESS="false"
rollback_on_failure <<< "y" >/dev/null 2>&1
HEADLESS="true"
assert_false "ERR-trap guard rolled back the recorded file" test -e "$RB_DIR/created-by-setup"

# --- Interrupt handler: same reachability, exits E_USER_ABORT ---
INT_DIR="$TEST_TMP/interrupt"
mkdir -p "$INT_DIR"
CONFIG[install_dir]="$INT_DIR"
MANIFEST_FILE=""
rollback_init_manifest
touch "$INT_DIR/created-before-ctrl-c"
rollback_snapshot "deploy" "FILE_CREATED" "$INT_DIR/created-before-ctrl-c"

MANIFEST_FILE=""
HEADLESS="false"
int_rc=0
( _on_interrupt <<< "y" ) >/dev/null 2>&1 || int_rc=$?
HEADLESS="true"
assert_eq "$E_USER_ABORT" "$int_rc" "interrupt handler exits E_USER_ABORT"
assert_false "interrupt handler rolled back the recorded file" test -e "$INT_DIR/created-before-ctrl-c"

# --- Cleanup removes both the manifest and the pointer it created ---
CONFIG[install_dir]="$RB_DIR"
MANIFEST_FILE=""
rollback_resolve_manifest || true
rollback_cleanup
assert_false "cleanup removed the manifest" test -e "$RB_MANIFEST"
assert_false "cleanup removed the pointer" test -e "$RB_POINTER"

# --- Two concurrent runs must not merge, and the first to finish must not
#     strand the second ---
CONC_DIR="$TEST_TMP/concurrent"
mkdir -p "$CONC_DIR"
CONFIG[install_dir]="$CONC_DIR"
MANIFEST_FILE=""
rollback_init_manifest
conc_manifest_a="$MANIFEST_FILE"
conc_pointer_a="$MANIFEST_POINTER"
MANIFEST_FILE=""
rollback_init_manifest
conc_manifest_b="$MANIFEST_FILE"

assert_ne "$conc_manifest_a" "$conc_manifest_b" "concurrent runs get separate manifests"

MANIFEST_FILE="$conc_manifest_a"
MANIFEST_POINTER="$conc_pointer_a"
rollback_cleanup
assert_false "first run's cleanup removed its own manifest" test -e "$conc_manifest_a"
assert_file_exists "$CONC_DIR/$MATRIX_SETUP_MANIFEST_FILE" "first run's cleanup left the second run's pointer"
MANIFEST_FILE=""
rollback_resolve_manifest || true
assert_eq "$conc_manifest_b" "$MANIFEST_FILE" "pointer still resolves to the second run's manifest"

# --- Fallback when install_dir is unwritable ---
RO_DIR="$TEST_TMP/unwritable"
mkdir -p "$RO_DIR"
chmod 500 "$RO_DIR"
CONFIG[install_dir]="$RO_DIR"
MANIFEST_FILE=""
rollback_init_manifest
assert_eq "$TMPDIR" "$(dirname "$MANIFEST_FILE")" "manifest falls back out of an unwritable install_dir"
assert_file_exists "$TMPDIR/$MATRIX_SETUP_MANIFEST_FILE" "pointer follows the manifest into the fallback dir"
fallback_manifest="$MANIFEST_FILE"
MANIFEST_FILE=""
rollback_resolve_manifest || true
assert_eq "$fallback_manifest" "$MANIFEST_FILE" "guard resolves a fallback manifest too"
rollback_cleanup
# Belt and braces: teardown only clears TEST_TMP, and a broken fallback would
# put these in the real /tmp.
rm -f "$fallback_manifest" \
      "$(dirname "$fallback_manifest")/$MATRIX_SETUP_MANIFEST_FILE"
chmod 700 "$RO_DIR"

# --- Cross-process: a fresh `setup.sh --rollback` finds a manifest left by an
#     earlier process. Needs a mapped-root user namespace for require_root. ---
if command -v unshare >/dev/null 2>&1 && unshare -r true 2>/dev/null; then
    XP_DIR="$TEST_TMP/crossproc"
    mkdir -p "$XP_DIR"
    printf 'install_dir = "%s"\n[domain]\nname = "matrix.example.com"\n' \
        "$XP_DIR" > "$TEST_TMP/crossproc.toml"

    # Subshell: the manifest must survive on disk, not in this shell.
    (
        CONFIG[install_dir]="$XP_DIR"
        MANIFEST_FILE=""
        rollback_init_manifest
        touch "$XP_DIR/left-behind"
        rollback_snapshot "deploy" "FILE_CREATED" "$XP_DIR/left-behind"
    )

    xp_rc=0
    unshare -r bash "$PROJECT_DIR/setup.sh" --rollback \
        --config "$TEST_TMP/crossproc.toml" >"$TEST_TMP/crossproc.log" 2>&1 || xp_rc=$?

    assert_eq "0" "$xp_rc" "setup.sh --rollback succeeds against another process's manifest"
    assert_false "setup.sh --rollback undid the recorded action" test -e "$XP_DIR/left-behind"
else
    skip_test "setup.sh --rollback cross-process (no usable user namespace)"
    skip_test "setup.sh --rollback undid the recorded action (no usable user namespace)"
fi

# =====================================================================
# Restoring a service the installer stopped.
#
# "Stop existing proxy and use Caddy" (lib/09_proxy_detect.sh) stops and
# disables the operator's nginx or apache. Undoing that means starting it
# again — but it was recorded as SERVICE_STARTED, whose handler stops and
# disables, so a rollback shut the proxy down a second time and then reported
# success. The round trip (record, then execute) is the only thing that shows
# it, so lib/09 is sourced here rather than tested in isolation.
#
# Everything below runs against a PATH stub. Rollback stops and disables
# services: no assertion here may reach the host's systemd.
# =====================================================================
source "$LIB_DIR/09_proxy_detect.sh"

SVC_STUB_BIN="$TEST_TMP/stub_bin"
mkdir -p "$SVC_STUB_BIN"
cat > "$SVC_STUB_BIN/systemctl" <<'SYSTEMCTL_STUB'
#!/usr/bin/env bash
# Records every invocation and answers from the environment. `--user` always
# fails, as it does for a system unit invoked with no user bus, so the
# fallback to the system manager is observable in the log.
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"

verb="" unit=""
for arg in "$@"; do
    [[ "$arg" == --* ]] && continue
    if [[ -z "$verb" ]]; then verb="$arg"; else unit="$arg"; fi
done

case "$verb" in
    is-active)  [[ " ${SYSTEMCTL_ACTIVE:-} "  == *" $unit "* ]] ;;
    is-enabled) [[ " ${SYSTEMCTL_ENABLED:-} " == *" $unit "* ]] ;;
    *)          [[ "$*" != *--user* && "${SYSTEMCTL_FAIL:-false}" != "true" ]] ;;
esac
SYSTEMCTL_STUB
chmod +x "$SVC_STUB_BIN/systemctl"

SVC_PATH_SAVED="$PATH"
export PATH="$SVC_STUB_BIN:$PATH"
export SYSTEMCTL_LOG="$TEST_TMP/systemctl.log"
export SYSTEMCTL_FAIL="false"

# --- A running, enabled proxy is recorded as stopped, not as started ---
SVC_DIR="$TEST_TMP/service"
mkdir -p "$SVC_DIR"
CONFIG[install_dir]="$SVC_DIR"
MANIFEST_FILE=""
rollback_init_manifest
SVC_MANIFEST="$MANIFEST_FILE"

: > "$SYSTEMCTL_LOG"
export SYSTEMCTL_ACTIVE="nginx"
export SYSTEMCTL_ENABLED="nginx"
_stop_existing_proxy >/dev/null 2>&1

assert_file_contains "$SYSTEMCTL_LOG" "^stop nginx$" \
    "the installer stopped the running proxy (guards the assertions below)"
assert_file_contains "$SVC_MANIFEST" "|SERVICE_STOPPED|nginx|true" \
    "stopping a running, enabled proxy is recorded as SERVICE_STOPPED"
assert_false "the stopped proxy is not recorded as one the installer started" \
    grep -q 'SERVICE_STARTED' "$SVC_MANIFEST"

# --- Rolling that back starts it again, rather than stopping it twice ---
: > "$SYSTEMCTL_LOG"
MANIFEST_FILE=""
rollback_execute_all >/dev/null 2>&1

assert_file_contains "$SYSTEMCTL_LOG" "^enable --now nginx$" \
    "rollback enables and starts the proxy it had stopped"
assert_false "rollback does not stop the proxy a second time" \
    grep -q '^stop nginx$' "$SYSTEMCTL_LOG"
assert_false "rollback does not disable the proxy a second time" \
    grep -q '^disable nginx$' "$SYSTEMCTL_LOG"

# --- A proxy that was running but not enabled comes back not enabled ---
# _stop_existing_proxy disables unconditionally, so what to restore depends on
# what was there: re-enabling a hand-started proxy would change its boot
# behaviour, and only starting an enabled one would lose it at the next boot.
NOEN_DIR="$TEST_TMP/service-not-enabled"
mkdir -p "$NOEN_DIR"
CONFIG[install_dir]="$NOEN_DIR"
MANIFEST_FILE=""
rollback_init_manifest
NOEN_MANIFEST="$MANIFEST_FILE"

: > "$SYSTEMCTL_LOG"
export SYSTEMCTL_ACTIVE="apache2"
export SYSTEMCTL_ENABLED=""
_stop_existing_proxy >/dev/null 2>&1

assert_file_contains "$NOEN_MANIFEST" "|SERVICE_STOPPED|apache2|false" \
    "a running but not-enabled proxy records that it was not enabled"

: > "$SYSTEMCTL_LOG"
MANIFEST_FILE=""
rollback_execute_all >/dev/null 2>&1

assert_file_contains "$SYSTEMCTL_LOG" "^start apache2$" \
    "rollback starts a proxy that was running but not enabled"
assert_false "rollback does not enable a proxy that was not enabled before" \
    grep -q 'enable --now apache2' "$SYSTEMCTL_LOG"

# --- A restore that fails is reported, and the rest of the rollback runs ---
# The manifest is replayed newest-first, so the file recorded first is undone
# after the service: if a failed restore aborted the run, it would survive.
FAILR_DIR="$TEST_TMP/service-restore-failure"
mkdir -p "$FAILR_DIR"
CONFIG[install_dir]="$FAILR_DIR"
MANIFEST_FILE=""
rollback_init_manifest
touch "$FAILR_DIR/created-by-setup"
rollback_snapshot "proxy" "FILE_CREATED" "$FAILR_DIR/created-by-setup"
rollback_snapshot "proxy" "SERVICE_STOPPED" "nginx|true"

: > "$SYSTEMCTL_LOG"
export SYSTEMCTL_FAIL="true"
MANIFEST_FILE=""
failr_out=$(rollback_execute_all 2>&1 || true)
export SYSTEMCTL_FAIL="false"

assert_match "nginx" "$failr_out" "a restore that fails names the service"
assert_match "systemctl enable --now nginx" "$failr_out" \
    "a restore that fails prints the command to run by hand"
assert_false "the rest of the rollback runs after a failed restore" \
    test -e "$FAILR_DIR/created-by-setup"

# --- SERVICE_STARTED still means "we started it": stop it ---
# The two arms are opposites; recording the wrong one is the whole defect.
: > "$SYSTEMCTL_LOG"
_rollback_action SERVICE_STARTED "matrix-compose.service" >/dev/null 2>&1
assert_file_contains "$SYSTEMCTL_LOG" "^stop matrix-compose" \
    "SERVICE_STARTED stops a service the installer started"
assert_false "SERVICE_STARTED does not start anything" \
    grep -q 'enable --now' "$SYSTEMCTL_LOG"

export PATH="$SVC_PATH_SAVED"
unset SYSTEMCTL_LOG SYSTEMCTL_FAIL SYSTEMCTL_ACTIVE SYSTEMCTL_ENABLED

teardown_test_tmp
test_report
