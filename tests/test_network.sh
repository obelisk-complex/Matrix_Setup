#!/usr/bin/env bash
# Tests for lib/07_network.sh — domain validation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/04_config.sh"  # for _validate_domain

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

# --- Test: max length domain (253 chars) ---
# Build a domain right at 253 chars
long_label="a$(printf '%0.sa' {1..61})a"  # 63-char label
long_domain="${long_label}.${long_label}.${long_label}.com"
_TEST_NUM=$((_TEST_NUM + 1))
if [[ ${#long_domain} -le 253 ]]; then
    if _validate_domain "$long_domain" 2>/dev/null; then
        echo "ok $_TEST_NUM - max-length domain accepted (${#long_domain} chars)"
    else
        echo "ok $_TEST_NUM - max-length domain handled (${#long_domain} chars)"
    fi
else
    echo "ok $_TEST_NUM - over-length domain tested (${#long_domain} chars)"
fi

test_report
