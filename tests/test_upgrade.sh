#!/usr/bin/env bash
# Tests for lib/26_upgrade.sh — `setup.sh --upgrade`.
#
# The stack is created rootless under the matrix user, so every container
# command the upgrade path issues has to be issued as that user: root's podman
# sees none of those containers. A probe that runs as root does not report "no
# such container", it reports nothing, which is why the PostgreSQL major-version
# guard has to fail closed.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/26_upgrade.sh"

setup_test_tmp

STUB_BIN="$TEST_TMP/stub_bin"
mkdir -p "$STUB_BIN"
export STUB_SUDO_LOG="$TEST_TMP/sudo.log"
export STUB_PODMAN_LOG="$TEST_TMP/podman.log"
export STUB_PG_VERSION="$TEST_TMP/pg_version"

cat > "$STUB_BIN/sudo" << 'STUB'
#!/usr/bin/env bash
# Records the target user with the command, then runs it in place.
user=""
if [[ "${1:-}" == "-u" ]]; then
    user="$2"
    shift 2
fi
[[ "${1:-}" == "--" ]] && shift
printf 'user=%s cmd=%s\n' "$user" "$*" >> "$STUB_SUDO_LOG"
exec "$@"
STUB

cat > "$STUB_BIN/podman" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_PODMAN_LOG"
case "$*" in
    *"SHOW server_version"*) cat "$STUB_PG_VERSION" ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/sudo" "$STUB_BIN/podman"
PATH="$STUB_BIN:$PATH"

INSTALL_DIR="$TEST_TMP/install"
mkdir -p "$INSTALL_DIR"
: > "$INSTALL_DIR/podman-compose.yml"

COMPOSE_CMD="podman compose"
# POSTGRES_IMAGE is the readonly pin from lib/00_constants.sh; the fixtures
# report a major that matches it and one that does not.
PINNED_PG_MAJOR="$(_pg_major_from_image "$POSTGRES_IMAGE")"

# Reset the stubs and run one upgrade. $1 is what the server reports for
# SHOW server_version (empty means the probe produced nothing at all).
run_upgrade() {
    local reported="$1"
    : > "$STUB_SUDO_LOG"
    : > "$STUB_PODMAN_LOG"
    printf '%s' "$reported" > "$STUB_PG_VERSION"

    declare -gA CONFIG=()
    CONFIG["install_dir"]="$INSTALL_DIR"
    CONFIG["matrix_user"]="matrix"
    CONFIG["database.user"]="${2:-synapse}"
    CONFIG["database.name"]="${3:-synapse}"

    UPGRADE_RC=0
    UPGRADE_OUT="$(upgrade_pull_images 2>&1)" || UPGRADE_RC=$?
}

# --- Test: a matching major version upgrades, as the matrix user ---
run_upgrade "${PINNED_PG_MAJOR}.4"
assert_eq "0" "$UPGRADE_RC" "a matching PostgreSQL major proceeds"
assert_true "the version probe runs as the matrix user" \
    grep -q 'user=matrix cmd=podman exec matrix-postgres psql' "$STUB_SUDO_LOG"
assert_true "the image pull runs as the matrix user" \
    grep -q 'user=matrix cmd=podman compose .* pull' "$STUB_SUDO_LOG"
assert_true "the restart runs as the matrix user" \
    grep -q 'user=matrix cmd=podman compose .* up -d' "$STUB_SUDO_LOG"
# The sudo log records the command line either way; only podman's own log shows
# that the two-word COMPOSE_CMD was split into a command and its subcommand
# rather than handed over as one unfindable binary name.
assert_true "the pull actually reaches podman" \
    grep -q '^compose -f .* pull$' "$STUB_PODMAN_LOG"
assert_true "the restart actually reaches podman" \
    grep -q '^compose -f .* up -d$' "$STUB_PODMAN_LOG"
assert_true "the upgrade path shells out at all (guards the assertion below)" \
    test -s "$STUB_SUDO_LOG"
assert_false "nothing in the upgrade path runs container commands as root" \
    grep -q '^user= ' "$STUB_SUDO_LOG"

# --- Test: the probe honours the configured database user and name ---
run_upgrade "${PINNED_PG_MAJOR}.4" "mtx" "matrixdb"
assert_true "the probe uses the configured database user" \
    grep -q 'psql -U mtx' "$STUB_PODMAN_LOG"
assert_true "the probe uses the configured database name" \
    grep -q -- '-d matrixdb' "$STUB_PODMAN_LOG"

# --- Test: a major version change is refused, before any pull ---
run_upgrade "$((PINNED_PG_MAJOR - 1)).7"
assert_ne "0" "$UPGRADE_RC" "a PostgreSQL major change aborts the upgrade"
assert_false "no image is pulled when the major version changed" \
    grep -q 'pull' "$STUB_PODMAN_LOG"

# --- Test: an unreadable version fails closed ---
# Running as root against a rootless stack produced exactly this: an empty
# answer, which used to skip the guard and pull anyway.
run_upgrade ""
assert_ne "0" "$UPGRADE_RC" "an unreadable server version aborts the upgrade"
assert_false "no image is pulled when the version could not be read" \
    grep -q 'pull' "$STUB_PODMAN_LOG"
assert_match "Cannot read the running PostgreSQL version" "$UPGRADE_OUT" \
    "the abort says the version could not be read, not that it changed"


# --- Test: every upgrade menu choice does something ---
# "Reconfigure settings" used to return 0 into a caller that then exited, so
# picking it was indistinguishable from picking "Abort".
STUB_CHOICE=0
prompt_select() { printf '%s\n' "$STUB_CHOICE"; }
upgrade_pull_images() { printf 'PULLED\n'; }
upgrade_bridges()     { printf 'BRIDGES\n'; }

declare -gA CONFIG=()
CONFIG["install_dir"]="$INSTALL_DIR"

STUB_CHOICE=0
menu_out="$(upgrade_prompt 2>&1)" || true
assert_match "PULLED" "$menu_out" "choice 1 pulls images"

STUB_CHOICE=1
reconf_rc=0
upgrade_prompt >/dev/null 2>&1 || reconf_rc=$?
assert_eq "$E_UPGRADE_RECONFIGURE" "$reconf_rc" \
    "choice 2 asks the caller to continue into the wizard"
assert_ne "0" "$E_UPGRADE_RECONFIGURE" \
    "the reconfigure signal is distinguishable from a completed action"

STUB_CHOICE=2
menu_out="$(upgrade_prompt 2>&1)" || true
assert_match "BRIDGES" "$menu_out" "choice 3 reconfigures bridges"

STUB_CHOICE=3
abort_rc=0
menu_out="$(upgrade_prompt 2>&1)" || abort_rc=$?
assert_eq "0" "$abort_rc" "choice 4 aborts cleanly"
assert_no_match "PULLED|BRIDGES" "$menu_out" "choice 4 changes nothing"

# --- Test: setup.sh --upgrade validates the config it was given ---
# `--upgrade` skipped config_validate entirely, so a config that would be
# rejected on install was accepted on upgrade.
if command -v unshare >/dev/null 2>&1 && unshare -r true 2>/dev/null; then
    UP_DIR="$TEST_TMP/upgrade-install"
    mkdir -p "$UP_DIR"
    printf 'version=0.1.1\ndomain.name=matrix.example.com\nhomeserver.type=synapse\n' \
        > "$UP_DIR/.matrix-setup.state"

    # retention_daily reaches an arithmetic context in the root-run backup timer.
    printf 'install_dir = "%s"\n[domain]\nname = "matrix.example.com"\n[backup]\nretention_daily = "a[$(id)]"\n' \
        "$UP_DIR" > "$TEST_TMP/upgrade-bad.toml"

    bad_rc=0
    unshare -r bash "$PROJECT_DIR/setup.sh" --upgrade --headless \
        --config "$TEST_TMP/upgrade-bad.toml" > "$TEST_TMP/upgrade-bad.log" 2>&1 || bad_rc=$?
    assert_ne "0" "$bad_rc" "setup.sh --upgrade rejects a config that fails validation"
    assert_file_contains "$TEST_TMP/upgrade-bad.log" "retention_daily" \
        "the upgrade names the setting it rejected"

    # The same run with a valid config must not be rejected by the headless
    # domain.confirmed rule: an existing install's domain is already confirmed.
    printf 'install_dir = "%s"\n[domain]\nname = "matrix.example.com"\n' \
        "$UP_DIR" > "$TEST_TMP/upgrade-ok.toml"
    ok_log="$TEST_TMP/upgrade-ok.log"
    unshare -r bash "$PROJECT_DIR/setup.sh" --upgrade --headless \
        --config "$TEST_TMP/upgrade-ok.toml" > "$ok_log" 2>&1 || true
    assert_false "a valid upgrade config is not rejected for domain.confirmed" \
        grep -q 'domain.confirmed' "$ok_log"
else
    skip_test "unshare unavailable - setup.sh --upgrade entry point not exercised"
fi

teardown_test_tmp
test_report
