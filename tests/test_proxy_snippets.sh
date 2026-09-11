#!/usr/bin/env bash
# Tests for the proxy snippets lib/09_proxy_detect.sh writes when it defers to
# an existing reverse proxy (FR-06).
#
# The snippets exist as templates under templates/snippets/ *and* as heredocs
# inside lib/09_proxy_detect.sh, and the two had diverged: the heredocs carried
# security headers the templates lacked, the templates carried .well-known
# bodies and a web-client route the heredocs lacked. These tests assert the
# properties FR-06 asks for, and that the file on disk is the rendered
# template, so the two cannot drift apart again unnoticed.
#
# lib/09_proxy_detect.sh's decision logic (which proxy, whether to skip Caddy)
# is covered by tests/test_network.sh; this file covers what gets written.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR_TEST/test_utils.sh"
source "$LIB_DIR/07_network.sh"
source "$LIB_DIR/09_proxy_detect.sh"

setup_test_tmp
trap teardown_test_tmp EXIT

SNIPPET_TEMPLATES="$PROJECT_DIR/templates/snippets"

# $1 = detected proxy, $2 = webclient type ("" for none)
generate_for() {
    local proxy="$1" webclient="${2:-}"

    rm -rf "$TEST_TMP/install"
    mkdir -p "$TEST_TMP/install"

    CONFIG=()
    CONFIG["domain.name"]="example.com"
    CONFIG["install_dir"]="$TEST_TMP/install"
    if [[ -n "$webclient" ]]; then
        CONFIG["webclient.type"]="$webclient"
        CONFIG["webclient.subdomain"]="chat"
    fi

    DETECTED_PROXY="$proxy"
    # Failure is reported by the assertions below. Letting errexit kill the run
    # here would truncate the file silently instead.
    _generate_proxy_snippet >/dev/null 2>&1 || true
}

SNIPPET_DIR() { printf '%s' "$TEST_TMP/install/proxy-snippets"; }

# The file on disk must be the rendered template, not a second copy of the
# same config kept somewhere else. The template's own first line is the marker:
# reading it here rather than hard-coding it keeps the check honest if the
# template is reworded.
assert_rendered_from_template() {
    local out="$1" tpl="$2" description="$3"
    local marker=""
    [[ -f "$tpl" ]] && marker=$(head -1 "$tpl")

    _TEST_NUM=$((_TEST_NUM + 1))
    if [[ -n "$marker" ]] && grep -Fq -- "$marker" "$out" 2>/dev/null; then
        echo "ok $_TEST_NUM - $description"
    else
        echo "not ok $_TEST_NUM - $description"
        echo "#   template: $tpl"
        echo "#   marker not found in $out: ${marker:-<template missing>}"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
}

assert_no_placeholders() {
    local out="$1" name="$2"
    local body
    body=$(cat "$out" 2>/dev/null || true)
    # Only `{{` is checked: `}}` occurs legitimately in the .well-known JSON.
    assert_no_match '{{' "$body" "$name: no unsubstituted placeholder or block marker remains"
}

# =====================================================================
# nginx
# =====================================================================

generate_for nginx
NGINX_OUT="$(SNIPPET_DIR)/matrix-nginx.conf"

assert_file_exists "$NGINX_OUT" "nginx: snippet is written"
assert_rendered_from_template "$NGINX_OUT" "$SNIPPET_TEMPLATES/nginx.conf.tpl" \
    "nginx: snippet is the rendered template, not a duplicate heredoc"
assert_no_placeholders "$NGINX_OUT" "nginx"

assert_file_contains "$NGINX_OUT" "example.com" "nginx: the domain is substituted"
assert_file_contains "$NGINX_OUT" "127.0.0.1:8008" "nginx: the homeserver backend is substituted"
assert_file_contains "$NGINX_OUT" "/.well-known/matrix/client" "nginx: .well-known client route"
assert_file_contains "$NGINX_OUT" "/.well-known/matrix/server" "nginx: .well-known server route"
assert_file_contains "$NGINX_OUT" 'm.homeserver' "nginx: .well-known client returns a body"
assert_file_contains "$NGINX_OUT" 'm.server' "nginx: .well-known server returns a body"
assert_file_contains "$NGINX_OUT" 'proxy_set_header Upgrade' "nginx: WebSocket upgrade for /sync"
assert_file_contains "$NGINX_OUT" 'Strict-Transport-Security' "nginx: HSTS header"
assert_file_contains "$NGINX_OUT" 'X-Content-Type-Options' "nginx: nosniff header"
assert_file_contains "$NGINX_OUT" 'X-Frame-Options' "nginx: frame options header"
assert_file_contains "$NGINX_OUT" 'Referrer-Policy' "nginx: referrer policy header"

# A bare include, not a whole server block: the admin already has one for this
# hostname, and a second would be a duplicate-server_name conflict.
nginx_body=$(cat "$NGINX_OUT")
assert_no_match 'server_name' "$nginx_body" \
    "nginx: snippet is an include, not a competing server block"

# nginx's own variables must survive rendering verbatim.
assert_file_contains "$NGINX_OUT" '$remote_addr' "nginx: nginx variables are not expanded by the renderer"

# nginx does not inherit add_header into a level that sets its own, so the
# .well-known locations have to repeat the security headers.
wellknown_block=$(sed -n '/location \/\.well-known\/matrix\/client/,/^}/p' "$NGINX_OUT")
assert_match 'Strict-Transport-Security' "$wellknown_block" \
    "nginx: .well-known client location repeats the security headers it would otherwise drop"

# =====================================================================
# Apache
# =====================================================================

generate_for apache
APACHE_OUT="$(SNIPPET_DIR)/matrix-apache.conf"

assert_file_exists "$APACHE_OUT" "apache: snippet is written"
assert_rendered_from_template "$APACHE_OUT" "$SNIPPET_TEMPLATES/apache.conf.tpl" \
    "apache: snippet is the rendered template, not a duplicate heredoc"
assert_no_placeholders "$APACHE_OUT" "apache"

assert_file_contains "$APACHE_OUT" "example.com" "apache: the domain is substituted"
assert_file_contains "$APACHE_OUT" "127.0.0.1:8008" "apache: the homeserver backend is substituted"
# Apache has no documented way to return a literal body without a file, so the
# discovery endpoints are proxied to the homeserver, which serves them from its
# own config. The route has to exist either way.
assert_file_contains "$APACHE_OUT" '/.well-known/matrix' "apache: .well-known is routed"
assert_file_contains "$APACHE_OUT" 'ws://127.0.0.1:8008' "apache: WebSocket upgrade for /sync"
assert_file_contains "$APACHE_OUT" 'Strict-Transport-Security' "apache: HSTS header"
assert_file_contains "$APACHE_OUT" 'X-Content-Type-Options' "apache: nosniff header"
assert_file_contains "$APACHE_OUT" 'X-Frame-Options' "apache: frame options header"

apache_directives=$(grep -v '^#' "$APACHE_OUT")
assert_no_match '<VirtualHost' "$apache_directives" \
    "apache: snippet is an include, not a competing VirtualHost"

# =====================================================================
# Traefik
# =====================================================================

generate_for traefik
TRAEFIK_OUT="$(SNIPPET_DIR)/matrix-traefik.yml"

assert_file_exists "$TRAEFIK_OUT" "traefik: snippet is written"
assert_rendered_from_template "$TRAEFIK_OUT" "$SNIPPET_TEMPLATES/traefik.yml.tpl" \
    "traefik: snippet is the rendered template, not a duplicate heredoc"
assert_no_placeholders "$TRAEFIK_OUT" "traefik"

assert_file_contains "$TRAEFIK_OUT" "example.com" "traefik: the domain is substituted"
assert_file_contains "$TRAEFIK_OUT" "http://127.0.0.1:8008" "traefik: the homeserver backend is substituted"
assert_file_contains "$TRAEFIK_OUT" '/.well-known/matrix' "traefik: .well-known is routed"
assert_file_contains "$TRAEFIK_OUT" 'stsSeconds' "traefik: HSTS via the headers middleware"
assert_file_contains "$TRAEFIK_OUT" 'contentTypeNosniff' "traefik: nosniff via the headers middleware"
assert_file_contains "$TRAEFIK_OUT" 'frameDeny' "traefik: frame options via the headers middleware"

# A middleware nothing references does nothing.
assert_file_contains "$TRAEFIK_OUT" 'middlewares:' "traefik: routers reference the middleware"

if command -v python3 >/dev/null 2>&1; then
    _TEST_NUM=$((_TEST_NUM + 1))
    if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$TRAEFIK_OUT" 2>/dev/null; then
        echo "ok $_TEST_NUM - traefik: rendered snippet is valid YAML"
    else
        echo "not ok $_TEST_NUM - traefik: rendered snippet is valid YAML"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
else
    skip_test "traefik YAML parse (python3 unavailable)"
fi

# --- The web-client block is conditional on a web client being configured ---

traefik_body=$(cat "$TRAEFIK_OUT")
assert_no_match 'matrix-webclient' "$traefik_body" \
    "traefik: no web-client route when no web client is deployed"

generate_for traefik element
assert_file_contains "$TRAEFIK_OUT" 'matrix-webclient' \
    "traefik: web-client route appears when a web client is deployed"
assert_file_contains "$TRAEFIK_OUT" 'chat.example.com' \
    "traefik: web-client route uses the configured subdomain"
assert_no_placeholders "$TRAEFIK_OUT" "traefik with web client"

# =====================================================================
# Unknown proxy
# =====================================================================

generate_for unknown
GENERIC_OUT="$(SNIPPET_DIR)/matrix-proxy-requirements.txt"

assert_file_exists "$GENERIC_OUT" "unknown proxy: requirements file is written"
assert_rendered_from_template "$GENERIC_OUT" "$SNIPPET_TEMPLATES/generic.txt.tpl" \
    "unknown proxy: requirements file is the rendered template"
assert_no_placeholders "$GENERIC_OUT" "generic"
assert_file_contains "$GENERIC_OUT" "example.com" "unknown proxy: the domain is substituted"
assert_file_contains "$GENERIC_OUT" "127.0.0.1:8008" "unknown proxy: the backend is substituted"
assert_file_contains "$GENERIC_OUT" "Strict-Transport-Security" "unknown proxy: required headers listed"

# =====================================================================
# A missing template is reported, not fatal
#
# template_render reads its input with `content=$(<"$input")`; a redirection
# error on a variable assignment exits a non-interactive shell, taking setup.sh
# with it before any handling here can run. The generator has to notice first.
# =====================================================================

# This has to run in a child shell. The failure mode is the *whole shell*
# exiting, and a command substitution would confine that to its subshell and
# hide it; the sentinel after the call is what proves the caller survived.
mkdir -p "$TEST_TMP/no-templates/templates/snippets"
cat > "$TEST_TMP/missing_template.sh" << CHILD
set -euo pipefail
source "$PROJECT_DIR/tests/test_utils.sh"
source "$LIB_DIR/07_network.sh"
source "$LIB_DIR/09_proxy_detect.sh"

SCRIPT_DIR="$TEST_TMP/no-templates"
CONFIG=()
CONFIG["domain.name"]="example.com"
CONFIG["install_dir"]="$TEST_TMP/install-missing"
DETECTED_PROXY="nginx"

rc=0
_generate_proxy_snippet || rc=\$?
printf 'CALLER_SURVIVED rc=%s\n' "\$rc"
CHILD

missing_out=$(bash "$TEST_TMP/missing_template.sh" 2>&1 || true)
assert_match "CALLER_SURVIVED" "$missing_out" \
    "a missing template does not terminate the caller"
assert_match "CALLER_SURVIVED rc=1" "$missing_out" \
    "a missing template makes the generator fail"
assert_match "not found" "$missing_out" "a missing template is named in the error"

# =====================================================================
# The templates are the only copy
# =====================================================================

lib_body=$(cat "$LIB_DIR/09_proxy_detect.sh")
for marker in 'server_name' 'ProxyPassReverse' 'certResolver'; do
    assert_no_match "$marker" "$lib_body" \
        "lib/09_proxy_detect.sh no longer carries its own copy of the snippets ($marker)"
done

# =====================================================================
# Permissions
# =====================================================================

# template_render inherits the caller's umask, which is 002 under some of the
# install paths, so an un-chmodded render lands group-writable.
mode=$(stat -c '%a' "$GENERIC_OUT")
assert_eq "644" "$mode" "matrix-proxy-requirements.txt is not group-writable"

generate_for nginx
mode=$(stat -c '%a' "$NGINX_OUT")
assert_eq "644" "$mode" "matrix-nginx.conf is not group-writable"

test_report
