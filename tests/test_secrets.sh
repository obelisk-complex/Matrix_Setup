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
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
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

# --- Podman secrets mode ---
# The podman branch shells out through run_as_user, which sudos. Replace both it
# and podman with a fake secret store on disk so the whole branch runs
# unprivileged and nothing touches the real secret store.
FAKE_SECRET_STORE="$TEST_TMP/podman-secrets"
FAKE_SHOWSECRET="supported"
PODMAN_CALLS="$TEST_TMP/podman-calls.log"
: > "$PODMAN_CALLS"

run_as_user() { "$@"; }

podman() {
    printf '%s\n' "$*" >> "$PODMAN_CALLS"
    case "$1 $2" in
        "secret exists")
            [[ -f "$FAKE_SECRET_STORE/$3" ]]
            ;;
        "secret create")
            mkdir -p "$FAKE_SECRET_STORE"
            cat > "$FAKE_SECRET_STORE/$3"  # value arrives on stdin
            ;;
        "secret inspect")
            if [[ "$FAKE_SHOWSECRET" != "supported" ]]; then
                echo "Error: unknown flag: --showsecret" >&2
                return 125
            fi
            local name="${!#}"
            if [[ ! -f "$FAKE_SECRET_STORE/$name" ]]; then
                echo "Error: no such secret $name" >&2
                return 125
            fi
            cat "$FAKE_SECRET_STORE/$name"
            ;;
        *)
            echo "unexpected podman invocation: $*" >&2
            return 127
            ;;
    esac
}

PODMAN_INSTALL="$TEST_TMP/podman-install"

reset_podman_config() {
    declare -gA CONFIG=()
    CONFIG[install_dir]="$PODMAN_INSTALL"
    CONFIG[domain.name]="test.example.com"
    CONFIG[secrets.mode]="podman"
}

gen_rc=0
run_generate() {
    gen_rc=0
    secrets_generate_all > "$TEST_TMP/generate.out" 2>&1 || gen_rc=$?
}

# secrets_generate_all exports the .env values into this shell, so a stale
# export from the block above could make a later assertion pass for the wrong
# reason.
unset REGISTRATION_SHARED_SECRET MACAROON_SECRET_KEY FORM_SECRET \
      POSTGRES_PASSWORD COTURN_SECRET REDIS_PASSWORD

# --- First run: six secrets created, no .env on disk ---
reset_podman_config
run_generate
assert_eq "0" "$gen_rc" "podman mode: first run generates secrets"
assert_false "podman mode: no .env is written" test -f "$PODMAN_INSTALL/.env"
assert_file_contains "$PODMAN_CALLS" "secret create matrix-postgres-password" \
    "podman mode: the podman stub was actually reached"
assert_eq "6" "$(find "$FAKE_SECRET_STORE" -type f | wc -l)" \
    "podman mode: all six secrets are stored"

first_registration="${CONFIG[secrets.registration_shared_secret]}"
first_macaroon="${CONFIG[secrets.macaroon_secret_key]}"
first_postgres="${CONFIG[secrets.postgres_password]}"

# --- Second run: reuse the stored values, do not mint new ones ---
# homeserver.yaml is re-rendered from CONFIG on every run. A fresh macaroon key
# invalidates every live access token, and a fresh postgres password stops
# matching the database that already exists on disk.
reset_podman_config
run_generate
assert_eq "0" "$gen_rc" "podman mode: second run succeeds"
assert_eq "$first_registration" "${CONFIG[secrets.registration_shared_secret]:-}" \
    "podman mode: second run reuses the stored registration secret"
assert_eq "$first_macaroon" "${CONFIG[secrets.macaroon_secret_key]:-}" \
    "podman mode: second run reuses the stored macaroon key"
assert_eq "$first_postgres" "${CONFIG[secrets.postgres_password]:-}" \
    "podman mode: second run reuses the stored postgres password"
assert_eq "$first_postgres" "$(<"$FAKE_SECRET_STORE/matrix-postgres-password")" \
    "podman mode: second run leaves the stored secret untouched"

# --- Grafana's password joins the set only when monitoring is deployed ---
# Minting a secret nothing consumes is how matrix-redis-password ended up inert,
# and it would break the re-run of every install that has no monitoring.
rm -rf "$FAKE_SECRET_STORE"
reset_podman_config
CONFIG[monitoring.enabled]="true"
run_generate
assert_eq "0" "$gen_rc" "podman mode: first run with monitoring succeeds"
assert_eq "7" "$(find "$FAKE_SECRET_STORE" -type f | wc -l)" \
    "podman mode: monitoring adds a seventh secret"
assert_file_exists "$FAKE_SECRET_STORE/matrix-grafana-password" \
    "podman mode: the grafana password is stored"
grafana_first="${CONFIG[secrets.grafana_admin_password]:-}"
assert_ne "admin" "$grafana_first" \
    "podman mode: the generated grafana password is not the built-in default"
assert_match '^[A-Za-z0-9+/=]{32,}$' "$grafana_first" \
    "podman mode: the grafana password is a generated secret, not a placeholder"
reset_podman_config
CONFIG[monitoring.enabled]="true"
run_generate
assert_eq "$grafana_first" "${CONFIG[secrets.grafana_admin_password]:-}" \
    "podman mode: second run reuses the stored grafana password"

# --- A half-present secret set is fatal, as a half-filled .env is ---
rm -f "$FAKE_SECRET_STORE/matrix-grafana-password"
rm -f "$FAKE_SECRET_STORE/matrix-form-secret"
reset_podman_config
run_generate
assert_ne "0" "$gen_rc" "podman mode: a partial secret set fails the run"
assert_file_contains "$TEST_TMP/generate.out" "matrix-form-secret" \
    "podman mode: the partial-set error names the missing secret"

# --- Podman too old to read a secret back must fail, not regenerate ---
printf '%s' "$first_macaroon" > "$FAKE_SECRET_STORE/matrix-form-secret"
FAKE_SHOWSECRET="unsupported"
reset_podman_config
run_generate
assert_ne "0" "$gen_rc" "podman mode: an unreadable secret set fails the run"
assert_file_contains "$TEST_TMP/generate.out" "4\.7" \
    "podman mode: the error names the podman version that can read secrets back"
assert_eq "" "${CONFIG[secrets.macaroon_secret_key]:-}" \
    "podman mode: no fresh macaroon key is minted when readback fails"
FAKE_SHOWSECRET="supported"

# --- Default mode is unchanged: .env is written and podman is never called ---
ENV_INSTALL="$TEST_TMP/env-install"
: > "$PODMAN_CALLS"

reset_env_config() {
    declare -gA CONFIG=()
    CONFIG[install_dir]="$ENV_INSTALL"
    CONFIG[domain.name]="test.example.com"
}

reset_env_config
run_generate
assert_eq "0" "$gen_rc" "env mode: first run generates secrets"
assert_file_exists "$ENV_INSTALL/.env" "env mode: .env is written"
assert_eq "" "$(<"$PODMAN_CALLS")" "env mode: podman is never invoked"
env_postgres="${CONFIG[secrets.postgres_password]}"

assert_eq "" "${CONFIG[secrets.grafana_admin_password]:-}" \
    "env mode: no grafana password without monitoring"
assert_false "env mode: .env carries no grafana password without monitoring" \
    grep -q GRAFANA_ADMIN_PASSWORD "$ENV_INSTALL/.env"

reset_env_config
run_generate
assert_eq "0" "$gen_rc" "env mode: second run succeeds"
assert_eq "$env_postgres" "${CONFIG[secrets.postgres_password]:-}" \
    "env mode: second run preserves the secrets from .env"

# --- env mode with monitoring: .env must carry a real Grafana password ---
MON_INSTALL="$TEST_TMP/monitoring-install"
unset GRAFANA_ADMIN_PASSWORD

reset_mon_config() {
    declare -gA CONFIG=()
    CONFIG[install_dir]="$MON_INSTALL"
    CONFIG[domain.name]="test.example.com"
    CONFIG[monitoring.enabled]="true"
}

reset_mon_config
run_generate
assert_eq "0" "$gen_rc" "env mode: monitoring install generates a grafana password"
assert_ne "admin" "${CONFIG[secrets.grafana_admin_password]:-}" \
    "env mode: the generated grafana password is not the built-in default"
assert_file_contains "$MON_INSTALL/.env" "^GRAFANA_ADMIN_PASSWORD=." \
    "env mode: .env carries a non-empty grafana password"
mon_grafana="${CONFIG[secrets.grafana_admin_password]:-}"

reset_mon_config
run_generate
assert_eq "$mon_grafana" "${CONFIG[secrets.grafana_admin_password]:-}" \
    "env mode: second run preserves the grafana password"

# Grafana sets admin_password once, on first run, so silently minting a
# replacement would print a password the running instance does not accept.
sed -i '/^GRAFANA_ADMIN_PASSWORD=/d' "$MON_INSTALL/.env"
unset GRAFANA_ADMIN_PASSWORD
reset_mon_config
run_generate
assert_ne "0" "$gen_rc" "env mode: a .env missing the grafana password fails the run"
assert_file_contains "$TEST_TMP/generate.out" "GRAFANA_ADMIN_PASSWORD" \
    "env mode: the error names the missing grafana variable"

teardown_test_tmp
test_report
