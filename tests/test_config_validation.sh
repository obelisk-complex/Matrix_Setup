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

# --- Test: cloudflare_api_token must be URL-safe base64 ---
for tok in 'abc|def' 'abc;def' 'abc def' 'tok$(id)' 'a/b'; do
    declare -gA CONFIG=()
    CONFIG[domain.name]="example.com"
    CONFIG[dns.cloudflare_api_token]="$tok"
    _config_apply_defaults
    assert_config_invalid "invalid cloudflare_api_token rejected: '$tok'"
done

for tok in "dQw4w9WgXcQ-1234567890abcdefABCDEF_ghi" "v1.0-abcdef123456"; do
    declare -gA CONFIG=()
    CONFIG[domain.name]="example.com"
    CONFIG[dns.cloudflare_api_token]="$tok"
    _config_apply_defaults
    assert_config_valid "valid cloudflare_api_token accepted: '$tok'"
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

test_report
