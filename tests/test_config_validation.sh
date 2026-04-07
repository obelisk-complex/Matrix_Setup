#!/usr/bin/env bash
# Tests for lib/04_config.sh — config validation
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/03_toml_parser.sh"
source "$LIB_DIR/04_config.sh"

# --- Test: valid minimal config passes ---
declare -gA CONFIG=()
HEADLESS="false"
CONFIG[domain.name]="example.com"
CONFIG[homeserver.type]="synapse"
_config_apply_defaults

if config_validate 2>/dev/null; then
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "ok $_TEST_NUM - valid minimal config passes"
else
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "not ok $_TEST_NUM - valid minimal config passes"
fi

# --- Test: missing domain fails ---
declare -gA CONFIG=()
HEADLESS="false"
CONFIG[domain.name]=""
_config_apply_defaults

if config_validate 2>/dev/null; then
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "not ok $_TEST_NUM - missing domain should fail"
else
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "ok $_TEST_NUM - missing domain fails validation"
fi

# --- Test: invalid domain format fails ---
declare -gA CONFIG=()
HEADLESS="false"
CONFIG[domain.name]="-bad-domain.com"
_config_apply_defaults

if config_validate 2>/dev/null; then
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "not ok $_TEST_NUM - invalid domain should fail"
else
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "ok $_TEST_NUM - invalid domain format fails"
fi

# --- Test: headless requires domain.confirmed ---
declare -gA CONFIG=()
HEADLESS="true"
CONFIG[domain.name]="example.com"
CONFIG[domain.confirmed]="false"
CONFIG[admin.username]="admin"
CONFIG[admin.password]="longpassword"
_config_apply_defaults

if config_validate 2>/dev/null; then
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "not ok $_TEST_NUM - headless without confirmed should fail"
else
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "ok $_TEST_NUM - headless requires domain.confirmed"
fi

# --- Test: dendrite + bridges = error ---
declare -gA CONFIG=()
HEADLESS="false"
CONFIG[domain.name]="example.com"
CONFIG[homeserver.type]="dendrite"
CONFIG[bridges.enabled]="telegram"
_config_apply_defaults

if config_validate 2>/dev/null; then
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "not ok $_TEST_NUM - dendrite+bridges should fail"
else
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "ok $_TEST_NUM - dendrite+bridges rejected"
fi

# --- Test: dendrite + admin_ui = error ---
declare -gA CONFIG=()
HEADLESS="false"
CONFIG[domain.name]="example.com"
CONFIG[homeserver.type]="dendrite"
CONFIG[admin_ui.enabled]="true"
_config_apply_defaults

if config_validate 2>/dev/null; then
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "not ok $_TEST_NUM - dendrite+admin_ui should fail"
else
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "ok $_TEST_NUM - dendrite+admin_ui rejected"
fi

# --- Test: open-email without SMTP fails ---
declare -gA CONFIG=()
HEADLESS="false"
CONFIG[domain.name]="example.com"
CONFIG[registration.policy]="open-email"
CONFIG[smtp.enabled]="false"
_config_apply_defaults

if config_validate 2>/dev/null; then
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "not ok $_TEST_NUM - open-email without SMTP should fail"
else
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "ok $_TEST_NUM - open-email requires SMTP"
fi

# --- Test: open-captcha without keys fails ---
declare -gA CONFIG=()
HEADLESS="false"
CONFIG[domain.name]="example.com"
CONFIG[registration.policy]="open-captcha"
_config_apply_defaults

if config_validate 2>/dev/null; then
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "not ok $_TEST_NUM - open-captcha without keys should fail"
else
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "ok $_TEST_NUM - open-captcha requires recaptcha keys"
fi

# --- Test: short admin password fails in headless ---
declare -gA CONFIG=()
HEADLESS="true"
CONFIG[domain.name]="example.com"
CONFIG[domain.confirmed]="true"
CONFIG[admin.username]="admin"
CONFIG[admin.password]="short"
_config_apply_defaults

if config_validate 2>/dev/null; then
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "not ok $_TEST_NUM - short password should fail"
else
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "ok $_TEST_NUM - admin password min 8 chars enforced"
fi

# --- Test: valid domain formats ---
HEADLESS="false"
for domain in "example.com" "matrix.example.org" "my-server.co.uk" "a.b"; do
    declare -gA CONFIG=()
    CONFIG[domain.name]="$domain"
    _config_apply_defaults
    if config_validate 2>/dev/null; then
        _TEST_NUM=$((_TEST_NUM + 1))
        echo "ok $_TEST_NUM - valid domain: $domain"
    else
        _TEST_NUM=$((_TEST_NUM + 1))
        echo "not ok $_TEST_NUM - valid domain should pass: $domain"
    fi
done

# --- Test: invalid domain formats ---
for domain in "localhost" ".leading-dot.com" "trailing-.com" ""; do
    declare -gA CONFIG=()
    CONFIG[domain.name]="$domain"
    _config_apply_defaults
    if config_validate 2>/dev/null; then
        _TEST_NUM=$((_TEST_NUM + 1))
        echo "not ok $_TEST_NUM - invalid domain should fail: '$domain'"
    else
        _TEST_NUM=$((_TEST_NUM + 1))
        echo "ok $_TEST_NUM - invalid domain rejected: '$domain'"
    fi
done

test_report
