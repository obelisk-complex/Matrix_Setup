#!/usr/bin/env bash
# Tests for lib/20_quadlet.sh — the units that start the stack on boot.
#
# podman-systemd.unit(5): "There is only one required key, Image, which defines
# the container image the service runs", and Quadlet units cannot be enabled
# with systemctl because the generator applies their [Install] section itself.
# A plain .service is enabled the ordinary way, by the symlink systemctl(1)
# describes enable as creating.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/20_quadlet.sh"

setup_test_tmp

rollback_snapshot() { :; }

# chown/systemctl are root-only; neither is what these tests are about.
STUB_BIN="$TEST_TMP/stub_bin"
mkdir -p "$STUB_BIN"
for stub in chown systemctl loginctl; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/$stub"
    chmod +x "$STUB_BIN/$stub"
done
PATH="$STUB_BIN:$PATH"

QUADLET_DIR="$TEST_TMP/containers-systemd"
USER_UNIT_DIR="$TEST_TMP/systemd-user"
INSTALL_DIR="$TEST_TMP/install"
mkdir -p "$QUADLET_DIR" "$USER_UNIT_DIR" "$INSTALL_DIR"

COMPOSE_CMD="podman compose"
declare -gA CONFIG=([matrix_user]="$USER")

_quadlet_generate_compose "$QUADLET_DIR" "$INSTALL_DIR" "$USER_UNIT_DIR" >/dev/null 2>&1

# --- Test: no .container unit is written that the generator would reject ---
# Image= is the one mandatory key, so a .container file without it produces no
# service at all. Assert over every unit the phase writes, rootless and rootful.
SYSTEM_QUADLET_DIR="$TEST_TMP/etc-containers-systemd"
mkdir -p "$SYSTEM_QUADLET_DIR"
export QUADLET_SYSTEM_DIR="$SYSTEM_QUADLET_DIR"
_quadlet_generate_coturn "$INSTALL_DIR" >/dev/null 2>&1

mapfile -t container_units < <(find "$QUADLET_DIR" "$SYSTEM_QUADLET_DIR" -name '*.container' | sort)
assert_ne "0" "${#container_units[@]}" \
    "the phase writes at least one .container unit to check"
for unit in "${container_units[@]}"; do
    assert_true "$(basename "$unit") declares the mandatory Image=" \
        grep -q '^Image=' "$unit"
done
assert_false "no placeholder matrix-stack.container is written" \
    test -f "$QUADLET_DIR/matrix-stack.container"

# --- Test: the compose wrapper is the boot path ---
COMPOSE_UNIT="$USER_UNIT_DIR/matrix-compose.service"
assert_file_exists "$COMPOSE_UNIT" "matrix-compose.service is written"
assert_file_contains "$COMPOSE_UNIT" \
    "ExecStart=podman compose -f $INSTALL_DIR/podman-compose.yml up -d" \
    "the compose service starts the assembled stack with the detected tool"
assert_file_contains "$COMPOSE_UNIT" "WantedBy=default.target" \
    "the compose service declares what it is wanted by"

# --- Test: the compose wrapper is actually enabled ---
# Without the symlink the unit exists but never runs on boot, which is the
# whole point of the module.
WANTS_LINK="$USER_UNIT_DIR/default.target.wants/matrix-compose.service"
assert_true "matrix-compose.service is linked into default.target.wants" \
    test -L "$WANTS_LINK"
assert_eq "$COMPOSE_UNIT" "$(readlink "$WANTS_LINK" 2>/dev/null || echo '<none>')" \
    "the wants symlink points at the generated unit"

# --- Test: re-running the phase is idempotent ---
_quadlet_generate_compose "$QUADLET_DIR" "$INSTALL_DIR" "$USER_UNIT_DIR" >/dev/null 2>&1
assert_true "a second run leaves the wants symlink in place" \
    test -L "$WANTS_LINK"
assert_eq "1" "$(find "$USER_UNIT_DIR/default.target.wants" -name 'matrix-compose.service*' | wc -l)" \
    "a second run does not duplicate the symlink"

teardown_test_tmp
test_report
