#!/usr/bin/env bash
# Tests for domain validation (_validate_domain from lib/04_config.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/04_config.sh"

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

    if _validate_domain "$domain"; then
        _TEST_NUM=$((_TEST_NUM + 1))
        echo "ok $_TEST_NUM - valid domain accepted: $domain"
    else
        _TEST_NUM=$((_TEST_NUM + 1))
        echo "not ok $_TEST_NUM - valid domain rejected: $domain"
    fi
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

    if _validate_domain "$domain" 2>/dev/null; then
        _TEST_NUM=$((_TEST_NUM + 1))
        echo "not ok $_TEST_NUM - invalid domain accepted: '$domain'"
    else
        _TEST_NUM=$((_TEST_NUM + 1))
        echo "ok $_TEST_NUM - invalid domain rejected: '$domain'"
    fi
done

# --- Test: over-length domain (>253 chars) should be rejected ---
long_label="a$(printf '%0.sa' {1..61})a"  # 63-char label
over_domain="${long_label}.${long_label}.${long_label}.${long_label}.com"
if _validate_domain "$over_domain" 2>/dev/null; then
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "not ok $_TEST_NUM - over-length domain should be rejected (${#over_domain} chars)"
else
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "ok $_TEST_NUM - over-length domain rejected (${#over_domain} chars)"
fi

test_report
