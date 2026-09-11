#!/usr/bin/env bash
# Tests for install-tree ownership and for the user timers that are supposed to
# run the generated scripts.
#
# Every container runs rootless as the matrix user, and the two timers are user
# units owned by that user, but the whole tree is written by root. A root-owned
# bind-mount source is not writable by the container, and a root-owned 0750
# script is not executable by the timer that names it.
#
# `systemctl --user enable` cannot be used from the installer: sudo provides no
# session bus. systemctl(1) defines enable as creating the symlinks encoded in
# [Install], so the installer creates them itself.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/06_user.sh"
source "$LIB_DIR/22_backup.sh"
source "$LIB_DIR/23_media_retention.sh"

setup_test_tmp

rollback_snapshot() { :; }
rollback_snapshot_sysctl() { :; }

MATRIX_USER="matrixtest"
FAKE_HOME="$TEST_TMP/home/$MATRIX_USER"
mkdir -p "$FAKE_HOME"

STUB_BIN="$TEST_TMP/stub_bin"
mkdir -p "$STUB_BIN"
export STUB_CHOWN_LOG="$TEST_TMP/chown.log"
export STUB_FAKE_HOME="$FAKE_HOME"
export STUB_MATRIX_USER="$MATRIX_USER"

cat > "$STUB_BIN/chown" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CHOWN_LOG"
exit 0
STUB

cat > "$STUB_BIN/getent" << 'STUB'
#!/usr/bin/env bash
# Only passwd lookups of the matrix user matter here.
if [[ "${1:-}" == "passwd" && "${2:-}" == "$STUB_MATRIX_USER" ]]; then
    printf '%s:x:9999:9999::%s:/bin/bash\n' "$STUB_MATRIX_USER" "$STUB_FAKE_HOME"
    exit 0
fi
exit 2
STUB

for stub in systemctl loginctl sudo podman; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/$stub"
done
chmod +x "$STUB_BIN"/*
PATH="$STUB_BIN:$PATH"

INSTALL_DIR="$TEST_TMP/install"
mkdir -p "$INSTALL_DIR/config" "$INSTALL_DIR/data/media"
: > "$INSTALL_DIR/config/homeserver.yaml"

declare -gA CONFIG=()
CONFIG["domain.name"]="example.com"
CONFIG["install_dir"]="$INSTALL_DIR"
CONFIG["matrix_user"]="$MATRIX_USER"
CONFIG["homeserver.type"]="synapse"
CONFIG["media_retention.days"]="30"

# --- Test: the install tree is handed to the matrix user ---
: > "$STUB_CHOWN_LOG"
install_dir_set_ownership >/dev/null 2>&1
assert_true "the install directory is chowned to the matrix user, recursively" \
    grep -q -- "-R $MATRIX_USER: $INSTALL_DIR" "$STUB_CHOWN_LOG"

# A missing directory is not an error: the phase can run on a config-only run.
rm -rf "$TEST_TMP/absent"
CONFIG["install_dir"]="$TEST_TMP/absent"
OWN_RC=0
install_dir_set_ownership >/dev/null 2>&1 || OWN_RC=$?
assert_eq "0" "$OWN_RC" "ownership on a tree that does not exist is a no-op, not a failure"
CONFIG["install_dir"]="$INSTALL_DIR"

# --- Test: ownership is applied before anything is deployed ---
# The containers read the tree during Deploy; a chown afterwards is too late.
SETUP_PHASES="$(grep -n 'run_phase ' "$PROJECT_DIR/setup.sh")"
# No match must produce an empty variable, not kill the run under errexit.
own_line=$(printf '%s\n' "$SETUP_PHASES" | grep -i 'ownership' | cut -d: -f1 | head -1 || true)
deploy_line=$(printf '%s\n' "$SETUP_PHASES" | grep '"Deploy"' | cut -d: -f1 | head -1 || true)
assert_ne "" "$own_line" "setup.sh runs an ownership phase"
assert_true "the ownership phase runs before Deploy" \
    test "${own_line:-999}" -lt "${deploy_line:-0}"

# --- Test: the backup timer can actually run the script it names ---
: > "$STUB_CHOWN_LOG"
CONFIG["backup.dir"]="$TEST_TMP/backups"
backup_setup >/dev/null 2>&1
BACKUP_SCRIPT="$INSTALL_DIR/scripts/backup.sh"
assert_file_exists "$BACKUP_SCRIPT" "the backup script is generated"
assert_true "the backup scripts are chowned to the user whose timer runs them" \
    grep -q -- "$MATRIX_USER: $INSTALL_DIR/scripts" "$STUB_CHOWN_LOG"

BACKUP_WANTS="$FAKE_HOME/.config/systemd/user/timers.target.wants/matrix-backup.timer"
assert_true "the backup timer is enabled (timers.target.wants symlink)" \
    test -L "$BACKUP_WANTS"
assert_eq "$FAKE_HOME/.config/systemd/user/matrix-backup.timer" \
    "$(readlink "$BACKUP_WANTS" 2>/dev/null || echo '<none>')" \
    "the backup timer symlink points at the generated unit"

# --- Test: the media cleanup timer is enabled the same way ---
media_retention_setup >/dev/null 2>&1
MEDIA_WANTS="$FAKE_HOME/.config/systemd/user/timers.target.wants/matrix-media-cleanup.timer"
assert_true "the media cleanup timer is enabled (timers.target.wants symlink)" \
    test -L "$MEDIA_WANTS"
assert_eq "$FAKE_HOME/.config/systemd/user/matrix-media-cleanup.timer" \
    "$(readlink "$MEDIA_WANTS" 2>/dev/null || echo '<none>')" \
    "the media timer symlink points at the generated unit"

teardown_test_tmp
test_report
