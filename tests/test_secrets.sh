#!/usr/bin/env bash
# Tests for lib/08_secrets.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/25_rollback.sh"
source "$LIB_DIR/08_secrets.sh"

setup_test_tmp

# Mock rollback_snapshot to be a no-op
rollback_snapshot() { :; }

# --- Test: _gen_secret produces base64 output ---
secret=$(_gen_secret)
assert_ne "" "$secret" "secret is not empty"
assert_match '^[A-Za-z0-9+/=]+$' "$secret" "secret is valid base64"

# --- Test: secrets are unique ---
secret1=$(_gen_secret)
secret2=$(_gen_secret)
assert_ne "$secret1" "$secret2" "two secrets are different"

# --- Test: secret length is reasonable (48 bytes base64 = 64 chars) ---
secret=$(_gen_secret)
len=${#secret}
_TEST_NUM=$((_TEST_NUM + 1))
if (( len >= 32 )); then
    echo "ok $_TEST_NUM - secret length >= 32 chars (got $len)"
else
    echo "not ok $_TEST_NUM - secret too short: $len chars"
fi

# --- Test: bridge token generation ---
declare -gA CONFIG=()
secrets_generate_bridge_tokens "telegram"

assert_ne "" "${CONFIG[secrets.telegram_as_token]:-}" "bridge as_token generated"
assert_ne "" "${CONFIG[secrets.telegram_hs_token]:-}" "bridge hs_token generated"
assert_ne "${CONFIG[secrets.telegram_as_token]}" "${CONFIG[secrets.telegram_hs_token]}" "as_token != hs_token"

# --- Test: env file generation ---
declare -gA CONFIG=()
CONFIG[install_dir]="$TEST_TMP"
CONFIG[domain.name]="test.example.com"
CONFIG[secrets.registration_shared_secret]="reg_secret_test"
CONFIG[secrets.macaroon_secret_key]="mac_secret_test"
CONFIG[secrets.form_secret]="form_secret_test"
CONFIG[secrets.postgres_password]="pg_pass_test"
CONFIG[secrets.coturn_secret]="turn_secret_test"
CONFIG[secrets.redis_password]="redis_pass_test"

_store_env_file "$TEST_TMP/.env"

assert_file_exists "$TEST_TMP/.env" ".env file created"
assert_file_contains "$TEST_TMP/.env" "REGISTRATION_SHARED_SECRET=reg_secret_test" ".env has registration secret"
assert_file_contains "$TEST_TMP/.env" "POSTGRES_PASSWORD=pg_pass_test" ".env has postgres password"
assert_file_contains "$TEST_TMP/.env" "COTURN_SECRET=turn_secret_test" ".env has coturn secret"
assert_file_contains "$TEST_TMP/.env" "MATRIX_DOMAIN=test.example.com" ".env has domain"

# Check permissions
perms=$(stat -c '%a' "$TEST_TMP/.env")
assert_eq "600" "$perms" ".env has 600 permissions"

teardown_test_tmp
test_report
