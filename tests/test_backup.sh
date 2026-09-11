#!/usr/bin/env bash
# Tests for lib/22_backup.sh — the generated backup and restore scripts.
#
# These run the generated scripts, not just their text: the scripts are the
# artefact the operator's timer executes, and every defect they carry (a dump
# against the wrong database, a retention policy that keeps 11 days while the
# config promises five weeks, a world-readable archive holding the signing key)
# only shows when the script runs.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/22_backup.sh"

setup_test_tmp

rollback_snapshot() { :; }

STUB_BIN="$TEST_TMP/stub_bin"
mkdir -p "$STUB_BIN"
export STUB_PODMAN_LOG="$TEST_TMP/podman.log"
export STUB_PODMAN_FAIL="$TEST_TMP/podman.fail"
export STUB_PGRESTORE_FAIL="$TEST_TMP/pgrestore.fail"

# podman: pg_dump writes a plausible dump on stdout; pg_restore succeeds unless
# the fixture asks it to fail. Everything else is recorded and ignored.
cat > "$STUB_BIN/podman" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_PODMAN_LOG"
[[ -f "$STUB_PODMAN_FAIL" ]] && exit 1
case "$*" in
    *pg_dump*)    printf 'PGDMP-stub\n' ;;
    *pg_restore*) cat > /dev/null
                  [[ -f "$STUB_PGRESTORE_FAIL" ]] && exit 1
                  ;;
esac
exit 0
STUB

# Host-side fallbacks and the tools the scripts probe with.
cat > "$STUB_BIN/pg_dump" << 'STUB'
#!/usr/bin/env bash
exit 1
STUB
cat > "$STUB_BIN/pg_restore" << 'STUB'
#!/usr/bin/env bash
# --list is the integrity check; it must accept the stub dump.
exit 0
STUB
# The detected compose tool under test is podman-compose, so a hardcoded
# `podman compose` in the generated script shows up as a podman stub call.
cat > "$STUB_BIN/podman-compose" << 'STUB'
#!/usr/bin/env bash
printf 'podman-compose %s\n' "$*" >> "$STUB_PODMAN_LOG"
exit 0
STUB

for stub in chown systemctl loginctl rclone; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/$stub"
done
chmod +x "$STUB_BIN"/*
PATH="$STUB_BIN:$PATH"

INSTALL_DIR="$TEST_TMP/install"
SCRIPTS_DIR="$INSTALL_DIR/scripts"
BACKUP_DIR="$TEST_TMP/backups"
mkdir -p "$SCRIPTS_DIR" "$INSTALL_DIR/config" "$INSTALL_DIR/data/signing-keys" \
         "$INSTALL_DIR/data/media" "$BACKUP_DIR"
printf 'signing key material\n' > "$INSTALL_DIR/data/signing-keys/example.com.signing.key"
printf 'media\n' > "$INSTALL_DIR/data/media/blob"
printf 'homeserver config\n' > "$INSTALL_DIR/config/homeserver.yaml"

COMPOSE_CMD="podman-compose"

generate_scripts() {
    declare -gA CONFIG=()
    CONFIG["domain.name"]="example.com"
    CONFIG["install_dir"]="$INSTALL_DIR"
    CONFIG["backup.dir"]="$BACKUP_DIR"
    CONFIG["backup.retention_daily"]="${1:-7}"
    CONFIG["backup.retention_weekly"]="${2:-4}"
    CONFIG["backup.encryption"]="none"
    CONFIG["database.user"]="${3:-synapse}"
    CONFIG["database.name"]="${4:-synapse}"
    CONFIG["matrix_user"]="$USER"
    _backup_generate_backup_script  "$SCRIPTS_DIR" "$INSTALL_DIR" "example.com" >/dev/null 2>&1
    _backup_generate_restore_script "$SCRIPTS_DIR" "$INSTALL_DIR" "example.com" >/dev/null 2>&1
}

run_backup() {
    : > "$STUB_PODMAN_LOG"
    BACKUP_RC=0
    BACKUP_OUT="$(bash "$SCRIPTS_DIR/backup.sh" 2>&1)" || BACKUP_RC=$?
}

# --- Test: the dump names the configured database, not a hardcoded one ---
generate_scripts 7 4 "mtx" "matrixdb"
run_backup
assert_eq "0" "$BACKUP_RC" "the backup script completes"
assert_true "pg_dump runs as the configured database user" \
    grep -q -- 'pg_dump -U mtx' "$STUB_PODMAN_LOG"
assert_true "pg_dump names the configured database" \
    grep -q -- 'matrixdb' "$STUB_PODMAN_LOG"

# --- Test: the archive is not readable by other local accounts ---
# It contains the signing key and every config secret; backups are unencrypted
# by default, so the file mode is the only thing protecting them.
ARCHIVE="$(find "$BACKUP_DIR" -name 'matrix-backup-*.tar.gz' | head -1)"
assert_ne "" "$ARCHIVE" "an archive was produced"
assert_eq "600" "$(stat -c '%a' "$ARCHIVE")" \
    "the archive is created 0600"
assert_eq "700" "$(stat -c '%a' "$BACKUP_DIR")" \
    "the backup directory is 0700"

# --- Test: a failed dump leaves nothing behind and fails the run ---
rm -rf "$BACKUP_DIR"/matrix-backup-*
touch "$STUB_PODMAN_FAIL"
run_backup
rm -f "$STUB_PODMAN_FAIL"
assert_ne "0" "$BACKUP_RC" "a failed database dump fails the backup"
assert_eq "0" "$(find "$BACKUP_DIR" -maxdepth 1 -type d -name 'matrix-backup-*' | wc -l)" \
    "a failed backup leaves no uncompressed copy of the installation behind"

# --- Test: retention keeps a daily tier AND a weekly tier ---
# The config advertises 7 daily + 4 weekly. Keeping the 11 most recent files
# gives an 11-day window, not the five weeks the operator was promised.
seed_archives() {
    rm -rf "$BACKUP_DIR"/matrix-backup-*
    local day
    # One archive a day for 60 days, newest first (day 0 == today).
    for day in $(seq 0 59); do
        local stamp
        stamp=$(date -u -d "-${day} days" +%Y%m%d)
        printf 'archive\n' > "$BACKUP_DIR/matrix-backup-${stamp}_030000.tar.gz"
    done
}

seed_archives
generate_scripts 7 4
run_backup
assert_eq "0" "$BACKUP_RC" "the backup script completes with a seeded history"

kept_count() { find "$BACKUP_DIR" -name 'matrix-backup-*.tar.gz' | wc -l; }

# The tiers are 7 + 4; what distinguishes them from "keep the 11 newest" is the
# span the survivors cover, asserted below.
assert_eq "11" "$(kept_count)" \
    "retention keeps 7 daily plus 4 weekly archives"

# The oldest survivor must be weeks old, not 11 days old.
oldest_stamp=$(find "$BACKUP_DIR" -name 'matrix-backup-*.tar.gz' -printf '%f\n' \
    | sed 's/matrix-backup-\([0-9]*\)_.*/\1/' | sort | head -1)
oldest_age_days=$(( ( $(date -u +%s) - $(date -u -d "$oldest_stamp" +%s) ) / 86400 ))
assert_true "the recovery window reaches back more than three weeks (got ${oldest_age_days}d)" \
    test "$oldest_age_days" -ge 21

# Every surviving weekly must fall in a distinct ISO week.
weeks=$(find "$BACKUP_DIR" -name 'matrix-backup-*.tar.gz' -printf '%f\n' \
    | sed 's/matrix-backup-\([0-9]*\)_.*/\1/' \
    | while read -r d; do date -u -d "$d" +%G-%V; done | sort -u | wc -l)
assert_true "the survivors span at least 5 distinct ISO weeks (got $weeks)" \
    test "$weeks" -ge 5

# --- Test: an unparseable filename is never deleted ---
seed_archives
printf 'not ours\n' > "$BACKUP_DIR/matrix-backup-unknown.tar.gz"
run_backup
assert_true "an archive whose name carries no timestamp is left alone" \
    test -f "$BACKUP_DIR/matrix-backup-unknown.tar.gz"
rm -f "$BACKUP_DIR/matrix-backup-unknown.tar.gz"

# --- Test: restore uses the detected compose tool and the configured database ---
generate_scripts 7 4 "mtx" "matrixdb"
rm -rf "$BACKUP_DIR"/matrix-backup-*
run_backup
ARCHIVE="$(find "$BACKUP_DIR" -name 'matrix-backup-*.tar.gz' | head -1)"

: > "$STUB_PODMAN_LOG"
RESTORE_RC=0
RESTORE_OUT="$(printf 'yes\n' | bash "$SCRIPTS_DIR/restore.sh" "$ARCHIVE" 2>&1)" || RESTORE_RC=$?
assert_eq "0" "$RESTORE_RC" "the restore script completes"
assert_true "restore drives the compose tool the installer detected" \
    grep -q 'compose' "$STUB_PODMAN_LOG"
assert_false "restore does not hardcode 'podman compose'" \
    grep -q -- '^compose -f' "$STUB_PODMAN_LOG"
assert_true "pg_restore targets the configured database user" \
    grep -q -- 'pg_restore -U mtx' "$STUB_PODMAN_LOG"
assert_true "pg_restore targets the configured database name" \
    grep -q -- '-d matrixdb' "$STUB_PODMAN_LOG"

# --- Test: a failed pg_restore is reported as a failure ---
: > "$STUB_PODMAN_LOG"
touch "$STUB_PGRESTORE_FAIL"
RESTORE_RC=0
RESTORE_OUT="$(printf 'yes\n' | bash "$SCRIPTS_DIR/restore.sh" "$ARCHIVE" 2>&1)" || RESTORE_RC=$?
rm -f "$STUB_PGRESTORE_FAIL"
assert_ne "0" "$RESTORE_RC" "a failed pg_restore fails the restore"
assert_no_match "Database restored" "$RESTORE_OUT" \
    "a failed pg_restore is not reported as success"

# --- Test: restore works onto a host with no install tree yet ---
CLEAN_DIR="$TEST_TMP/clean-host"
rm -rf "$CLEAN_DIR"
mkdir -p "$CLEAN_DIR"
CLEAN_SCRIPTS="$CLEAN_DIR/scripts"
mkdir -p "$CLEAN_SCRIPTS"
declare -gA CONFIG=()
CONFIG["domain.name"]="example.com"
CONFIG["install_dir"]="$CLEAN_DIR"
CONFIG["database.user"]="mtx"
CONFIG["database.name"]="matrixdb"
_backup_generate_restore_script "$CLEAN_SCRIPTS" "$CLEAN_DIR" "example.com" >/dev/null 2>&1
RESTORE_RC=0
RESTORE_OUT="$(printf 'yes\n' | bash "$CLEAN_SCRIPTS/restore.sh" "$ARCHIVE" 2>&1)" || RESTORE_RC=$?
assert_eq "0" "$RESTORE_RC" "restore onto a clean host succeeds"
assert_file_exists "$CLEAN_DIR/data/signing-keys/example.com.signing.key" \
    "the signing key is restored onto a host that had no install tree"
assert_file_exists "$CLEAN_DIR/config/homeserver.yaml" \
    "the configuration is restored onto a host that had no install tree"

teardown_test_tmp
test_report
