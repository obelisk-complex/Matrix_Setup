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

test_report
