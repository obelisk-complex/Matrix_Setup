#!/usr/bin/env bash
# Regression tests for the QA-fleet security/correctness fixes.
# Each test pins a specific remediation so it cannot silently regress.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/03_toml_parser.sh"
source "$LIB_DIR/04_config.sh"
source "$LIB_DIR/25_rollback.sh"
source "$LIB_DIR/08_secrets.sh"
source "$LIB_DIR/10_hardening.sh"
source "$LIB_DIR/16_bridges.sh"
source "$LIB_DIR/26_upgrade.sh"

# Stub state-changing helpers used by the libs under test.
rollback_snapshot() { :; }
rollback_snapshot_file() { :; }

# config_validate helpers (suppress the expected [ERROR] diagnostics on stderr)
assert_valid()   { _TEST_NUM=$((_TEST_NUM + 1)); if config_validate 2>/dev/null; then echo "ok $_TEST_NUM - $1"; else echo "not ok $_TEST_NUM - $1"; _TEST_FAILURES=$((_TEST_FAILURES + 1)); fi; }
assert_invalid() { _TEST_NUM=$((_TEST_NUM + 1)); if config_validate 2>/dev/null; then echo "not ok $_TEST_NUM - $1"; _TEST_FAILURES=$((_TEST_FAILURES + 1)); else echo "ok $_TEST_NUM - $1"; fi; }

reset_valid_config() {
    declare -gA CONFIG=()
    HEADLESS="false"
    CONFIG[domain.name]="matrix.example.com"
    CONFIG[homeserver.type]="synapse"
    _config_apply_defaults
}

setup_test_tmp

# =====================================================================
# 1. Config validation — injection vectors are rejected at the source
# =====================================================================

# Baseline must pass, otherwise the negative tests prove nothing.
reset_valid_config
assert_valid "baseline default config is valid"

# matrix_user (eval/shell sink)
reset_valid_config; CONFIG[matrix_user]='evil; rm -rf /'
assert_invalid "matrix_user with shell metacharacters rejected"
reset_valid_config; CONFIG[matrix_user]='matrix_1'
assert_valid "valid matrix_user accepted"

# install_dir (path / shell sink)
reset_valid_config; CONFIG[install_dir]='relative/dir'
assert_invalid "relative install_dir rejected"
reset_valid_config; CONFIG[install_dir]='/opt/../etc'
assert_invalid "install_dir with traversal rejected"
reset_valid_config; CONFIG[install_dir]='/opt/matrix; touch x'
assert_invalid "install_dir with shell metacharacters rejected"
reset_valid_config; CONFIG[install_dir]='/opt/matrix'
assert_valid "valid absolute install_dir accepted"

# database.user / database.name (SQL identifier sink)
reset_valid_config; CONFIG[database.user]="syn'; DROP TABLE x;--"
assert_invalid "database.user with SQL metacharacters rejected"
reset_valid_config; CONFIG[database.name]="syn'apse"
assert_invalid "database.name with quote rejected"
reset_valid_config; CONFIG[database.user]="synapse"; CONFIG[database.name]="synapse"
assert_valid "valid database identifiers accepted"

# admin.username (JSON body sink)
reset_valid_config; CONFIG[admin.username]='bad"user'
assert_invalid "admin.username with JSON-breaking chars rejected"
reset_valid_config; CONFIG[admin.username]='alice'
assert_valid "valid admin.username accepted"

# admin.password placeholder blocklist
reset_valid_config; CONFIG[admin.password]='changeme-at-least-8-chars'
assert_invalid "placeholder admin.password rejected"
reset_valid_config; CONFIG[admin.password]='S7rong!example#pass'
assert_valid "strong admin.password accepted"

# bridges.enabled (path traversal -> source sink)
reset_valid_config; CONFIG[bridges.enabled]='../../tmp/payload'
assert_invalid "bridges.enabled traversal rejected"
reset_valid_config; CONFIG[bridges.enabled]='telegram,../evil'
assert_invalid "bridges.enabled with one bad entry rejected"
reset_valid_config; CONFIG[bridges.enabled]='telegram,discord'
assert_valid "valid bridges.enabled accepted"

# Ports — arithmetic-injection style value must be rejected WITHOUT evaluating
reset_valid_config; CONFIG[coturn.min_port]='abc'
assert_invalid "non-numeric coturn.min_port rejected"
reset_valid_config; CONFIG[coturn.min_port]='70000'
assert_invalid "out-of-range coturn.min_port rejected"
reset_valid_config; CONFIG[coturn.min_port]='60000'; CONFIG[coturn.max_port]='50000'
assert_invalid "coturn.min_port >= max_port rejected"
rm -f "$TEST_TMP/pwned_port"
reset_valid_config; CONFIG[coturn.min_port]="9[\$(touch '$TEST_TMP/pwned_port')]9"
assert_invalid "arithmetic-injection coturn.min_port rejected"
_TEST_NUM=$((_TEST_NUM + 1))
if [[ ! -e "$TEST_TMP/pwned_port" ]]; then echo "ok $_TEST_NUM - port validation did not evaluate injected command"; else echo "not ok $_TEST_NUM - port injection executed!"; _TEST_FAILURES=$((_TEST_FAILURES + 1)); fi

# media_retention.days arithmetic-injection guard
rm -f "$TEST_TMP/pwned_days"
reset_valid_config; CONFIG[media_retention.days]="9\$(touch '$TEST_TMP/pwned_days')"
assert_invalid "non-integer media_retention.days rejected"
_TEST_NUM=$((_TEST_NUM + 1))
if [[ ! -e "$TEST_TMP/pwned_days" ]]; then echo "ok $_TEST_NUM - media_retention validation did not evaluate injected command"; else echo "not ok $_TEST_NUM - media_retention injection executed!"; _TEST_FAILURES=$((_TEST_FAILURES + 1)); fi

# =====================================================================
# 2. get_user_home resolves via getent (no eval)
# =====================================================================
_cur_user=$(id -un)
_expected_home=$(getent passwd "$_cur_user" | cut -d: -f6)
assert_eq "$_expected_home" "$(get_user_home "$_cur_user")" "get_user_home matches getent for current user"
assert_false "get_user_home fails for a nonexistent user" get_user_home "no_such_user_xyzzy_42"

# =====================================================================
# 3. secrets_generate_all idempotency + 0600 permissions
# =====================================================================
declare -gA CONFIG=()
CONFIG[install_dir]="$TEST_TMP/secrets"
CONFIG[domain.name]="test.example.com"
CONFIG[secrets.mode]="env"
mkdir -p "$TEST_TMP/secrets"
secrets_generate_all >/dev/null 2>&1
pass1=$(grep '^POSTGRES_PASSWORD=' "$TEST_TMP/secrets/.env" | cut -d= -f2-)
secrets_generate_all >/dev/null 2>&1   # second run must preserve, not regenerate
pass2=$(grep '^POSTGRES_PASSWORD=' "$TEST_TMP/secrets/.env" | cut -d= -f2-)
assert_ne "" "$pass1" "secrets_generate_all wrote a postgres password"
assert_eq "$pass1" "$pass2" "secrets_generate_all is idempotent (preserves existing .env)"
assert_eq "600" "$(stat -c '%a' "$TEST_TMP/secrets/.env")" "generated .env is mode 0600"

# =====================================================================
# 4. _harden_nftables actually APPLIES the ruleset (fail-open fix)
# =====================================================================
declare -gA CONFIG=()
CONFIG[install_dir]="$TEST_TMP/hard"
CONFIG[federation.enabled]="true"
CURRENT_PHASE="hardening"
mkdir -p "$TEST_TMP/hard"
rm -f "$TEST_TMP/hard/nft.log"
nft() { echo "nft $*" >> "$TEST_TMP/hard/nft.log"; }       # stub: record invocation
systemctl() { :; }                                          # stub
_harden_nftables >/dev/null 2>&1
assert_file_exists "$TEST_TMP/hard/matrix-nftables.conf" "nftables rules file written"
assert_file_exists "$TEST_TMP/hard/nft.log" "nft was invoked (rules applied, not just written)"
assert_file_contains "$TEST_TMP/hard/nft.log" "matrix-nftables.conf" "nft applied the generated ruleset file"
unset -f nft systemctl

# =====================================================================
# 5. Bridge name guard rejects traversal / unknown plugins before source
# =====================================================================
declare -gA BRIDGE_NAMES=([telegram]="mautrix-telegram")
declare -ga BRIDGES_ENABLED=()
_bridge_setup_single "../etc/passwd" "$TEST_TMP" >/dev/null 2>&1 || true
assert_eq "0" "${#BRIDGES_ENABLED[@]}" "path-traversal bridge name not enabled"
_bridge_setup_single "totally_unknown_bridge" "$TEST_TMP" >/dev/null 2>&1 || true
assert_eq "0" "${#BRIDGES_ENABLED[@]}" "unknown bridge name not enabled"

# =====================================================================
# 6. Rollback execution path (FILE_CREATED / FILE_BACKUP / SYSCTL_SET)
# =====================================================================
declare -gA CONFIG=()
CONFIG[install_dir]="$TEST_TMP/rb"
mkdir -p "$TEST_TMP/rb"
rollback_init_manifest

# Restore the real snapshot recorder for this section (we stubbed it above).
unset -f rollback_snapshot
rollback_snapshot() {
    [[ -n "$MANIFEST_FILE" && -f "$MANIFEST_FILE" ]] || return 0
    echo "$(date +%s)|$1|$2|$3" >> "$MANIFEST_FILE"
}

touch "$TEST_TMP/rb/created.txt"
rollback_snapshot "p" "FILE_CREATED" "$TEST_TMP/rb/created.txt"

echo "original" > "$TEST_TMP/rb/orig.txt"
cp "$TEST_TMP/rb/orig.txt" "$TEST_TMP/rb/orig.txt.bak"
echo "modified" > "$TEST_TMP/rb/orig.txt"
rollback_snapshot "p" "FILE_BACKUP" "$TEST_TMP/rb/orig.txt.bak|$TEST_TMP/rb/orig.txt"

sysctl_calls="$TEST_TMP/rb/sysctl.log"
sysctl() { echo "sysctl $*" >> "$sysctl_calls"; }
rollback_snapshot "p" "SYSCTL_SET" "net.ipv4.tcp_syncookies|0"

rollback_execute_all >/dev/null 2>&1

_TEST_NUM=$((_TEST_NUM + 1))
if [[ ! -f "$TEST_TMP/rb/created.txt" ]]; then echo "ok $_TEST_NUM - FILE_CREATED removed on rollback"; else echo "not ok $_TEST_NUM - FILE_CREATED not removed"; _TEST_FAILURES=$((_TEST_FAILURES + 1)); fi
assert_eq "original" "$(cat "$TEST_TMP/rb/orig.txt")" "FILE_BACKUP restored original content"
assert_file_contains "$sysctl_calls" "net.ipv4.tcp_syncookies=0" "SYSCTL_SET restored previous value"
unset -f sysctl

# =====================================================================
# 7. Upgrade PG-major parse is digest-pinning aware
# =====================================================================
assert_eq "16" "$(_pg_major_from_image 'docker.io/postgres:16.14-alpine@sha256:abc123')" "pg major parsed from digest-pinned ref"
assert_eq "16" "$(_pg_major_from_image 'docker.io/postgres:16-alpine')" "pg major parsed from tag-only ref"
assert_eq "15" "$(_pg_major_from_image 'docker.io/postgres:15.6')" "pg major parsed from plain version tag"
assert_eq "" "$(_pg_major_from_image 'docker.io/postgres@sha256:deadbeef')" "digest-only ref yields empty (guard skipped, not errored)"

teardown_test_tmp
test_report
