#!/usr/bin/env bash
# Tests for domain validation (_validate_domain from lib/04_config.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/04_config.sh"

# Helpers — properly track failures via _TEST_FAILURES
assert_domain_valid() {
    local domain="$1"
    _TEST_NUM=$((_TEST_NUM + 1))
    if _validate_domain "$domain" 2>/dev/null; then
        echo "ok $_TEST_NUM - valid domain accepted: $domain"
    else
        echo "not ok $_TEST_NUM - valid domain rejected: $domain"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
}

assert_domain_invalid() {
    local domain="$1"
    _TEST_NUM=$((_TEST_NUM + 1))
    if _validate_domain "$domain" 2>/dev/null; then
        echo "not ok $_TEST_NUM - invalid domain accepted: '$domain'"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    else
        echo "ok $_TEST_NUM - invalid domain rejected: '$domain'"
    fi
}

# --- Test: valid domains ---
for domain in \
    "example.com" \
    "matrix.example.org" \
    "my-server.co.uk" \
    "sub.domain.example.com" \
    "a.b" \
    "x-y.z-w.com" \
    "123.example.com" \
    "a1b2.c3d4.com"; do
    assert_domain_valid "$domain"
done

# --- Test: invalid domains ---
for domain in \
    "localhost" \
    ".leading-dot.com" \
    "trailing-dot.com." \
    "-leading-hyphen.com" \
    "trailing-hyphen-.com" \
    "" \
    "has space.com" \
    "under_score.com" \
    "way-too-long-label-that-exceeds-sixty-three-characters-in-a-single-label-part.com"; do
    assert_domain_invalid "$domain"
done

# --- Test: over-length domain (>253 chars) should be rejected ---
long_label="a$(printf '%0.sa' {1..61})a"  # 63-char label
over_domain="${long_label}.${long_label}.${long_label}.${long_label}.com"
assert_domain_invalid "$over_domain"

test_report
