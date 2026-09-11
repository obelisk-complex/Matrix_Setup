#!/usr/bin/env bash
# Tests for lib/13_caddy.sh — the generated Caddyfile.
#
# `acme_dns cloudflare` needs a DNS provider module. Caddy ships provider
# modules only in custom builds, and CADDY_IMAGE is the stock
# docker.io/library/caddy image, so emitting the directive produces a proxy that
# will not start — and it takes 80/443 with it, so the whole stack is
# unreachable. The Cloudflare token is now read nowhere at all (the DNS-record
# writer in lib/07_network.sh has no call sites), so a config carried over from
# an earlier version must still produce a working Caddy.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR_TEST/test_utils.sh"
source "$LIB_DIR/13_caddy.sh"

setup_test_tmp

rollback_snapshot() { :; }

INSTALL_DIR="$TEST_TMP/install"
CADDYFILE="$INSTALL_DIR/config/Caddyfile"

render_caddy() {
    declare -gA CONFIG=()
    CONFIG["domain.name"]="example.com"
    CONFIG["install_dir"]="$INSTALL_DIR"
    CONFIG["federation.enabled"]="true"
    CONFIG["webclient.type"]="element"
    CONFIG["admin_ui.enabled"]="false"
    CONFIG["monitoring.enabled"]="false"
    [[ -n "${1:-}" ]] && CONFIG["dns.cloudflare_api_token"]="$1"
    rm -f "$CADDYFILE"
    CADDY_OUT="$(caddy_setup 2>&1)" || return 1
}

# --- Test: no Cloudflare token — unchanged behaviour ---
render_caddy
assert_file_exists "$CADDYFILE" "the Caddyfile is written"
assert_file_contains "$CADDYFILE" "example.com" "the Caddyfile carries the domain"
assert_false "no acme_dns directive without a token" \
    grep -q 'acme_dns' "$CADDYFILE"

# --- Test: a Cloudflare token must not make Caddy unstartable ---
render_caddy "cf-token-value"
assert_file_exists "$CADDYFILE" "the Caddyfile is written when a token is configured"
assert_false "a Cloudflare token does not emit acme_dns into a stock Caddy image" \
    grep -q 'acme_dns' "$CADDYFILE"
assert_false "the Cloudflare token is not written into the Caddyfile" \
    grep -q 'cf-token-value' "$CADDYFILE"
assert_match "DNS-01" "$CADDY_OUT" \
    "the operator is told DNS-01 is not in use, rather than left to discover it"

# --- Test: the rest of the Caddyfile is unaffected by the token ---
render_caddy "cf-token-value"
with_token="$(grep -c . "$CADDYFILE")"
render_caddy
without_token="$(grep -c . "$CADDYFILE")"
assert_eq "$without_token" "$with_token" \
    "the token changes nothing else in the generated Caddyfile"

# --- Test: the pinned image is the stock one this decision rests on ---
assert_match '^docker\.io/library/caddy:' "$CADDY_IMAGE" \
    "CADDY_IMAGE is the stock Caddy image (no DNS provider modules)"

teardown_test_tmp
test_report
