#!/usr/bin/env bash
# Tests for lib/07_network.sh (domain/DNS/port checks) and lib/09_proxy_detect.sh
# (existing-proxy detection and the skip-Caddy decision it records in CONFIG).
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/03_toml_parser.sh"
source "$LIB_DIR/04_config.sh"
source "$LIB_DIR/07_network.sh"
source "$LIB_DIR/09_proxy_detect.sh"
source "$LIB_DIR/19_compose.sh"

setup_test_tmp
trap teardown_test_tmp EXIT

# Helpers — properly track failures via _TEST_FAILURES.
# Exercised through network_validate_domain so this file covers 07_network.sh's
# entry point rather than reaching past it into _validate_domain.
assert_domain_valid() {
    local domain="$1"
    _TEST_NUM=$((_TEST_NUM + 1))
    if network_validate_domain "$domain" 2>/dev/null; then
        echo "ok $_TEST_NUM - valid domain accepted: $domain"
    else
        echo "not ok $_TEST_NUM - valid domain rejected: $domain"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
}

assert_domain_invalid() {
    local domain="$1"
    _TEST_NUM=$((_TEST_NUM + 1))
    if network_validate_domain "$domain" 2>/dev/null; then
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

# =====================================================================
# network_check_ports — parses the listening process out of ss output
# =====================================================================
# Stub `ss`. It must always exit 0: the callers pipe it into `tail`, and this
# file runs under `pipefail`, so a non-zero producer would abort the run
# instead of being read as "port free".
STUB_PORT_80=""
STUB_PORT_443=""
ss() {
    case "$*" in
        *":80"*)  [[ -n "$STUB_PORT_80"  ]] && printf '%s\n' "$STUB_PORT_80" ;;
        *":443"*) [[ -n "$STUB_PORT_443" ]] && printf '%s\n' "$STUB_PORT_443" ;;
    esac
    return 0
}

NGINX_80='LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=1234,fd=6))'
NGINX_443='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=1234,fd=8))'

STUB_PORT_80=""; STUB_PORT_443=""
assert_true "network_check_ports succeeds when 80 and 443 are free" network_check_ports
assert_eq "" "$PORT_80_PROCESS" "no process recorded for a free port 80"
assert_eq "" "$PORT_443_PROCESS" "no process recorded for a free port 443"

STUB_PORT_80="$NGINX_80"; STUB_PORT_443=""
assert_false "network_check_ports fails when port 80 is bound" network_check_ports
assert_eq "nginx" "$PORT_80_PROCESS" "process name extracted from ss output for port 80"

STUB_PORT_80=""; STUB_PORT_443="$NGINX_443"
assert_false "network_check_ports fails when port 443 is bound" network_check_ports
assert_eq "nginx" "$PORT_443_PROCESS" "process name extracted from ss output for port 443"

# A bound socket whose owning process ss cannot name still counts as in use.
STUB_PORT_80='LISTEN 0 511 0.0.0.0:80 0.0.0.0:*'; STUB_PORT_443=""
assert_false "network_check_ports fails for a bound port with no users:(()) field" network_check_ports
assert_eq "unknown" "$PORT_80_PROCESS" "unnamed listener recorded as 'unknown'"

# The header line ss prints when nothing matches must not be read as a process.
STUB_PORT_80='State Recv-Q Send-Q Local Address:Port Peer Address:Port Process'; STUB_PORT_443=""
assert_true "network_check_ports treats an ss header-only response as free" network_check_ports

# =====================================================================
# proxy_detect — records its outcome in CONFIG so later phases can read it
# =====================================================================
# CONFIG[proxy.external] is the single source of truth: lib/19_compose.sh reads
# it to decide whether to include the Caddy fragment, and lib/27_wizard.sh reads
# CONFIG[proxy.detected] to report what was found.
reset_proxy_config() {
    declare -gA CONFIG=()
    CONFIG["domain.name"]="matrix.example.com"
    CONFIG["install_dir"]="$TEST_TMP/proxy"
    mkdir -p "$TEST_TMP/proxy"
    DETECTED_PROXY=""
    : > "$PROMPT_LOG"
}

# prompt_select is called as `choice=$(prompt_select ...)`, so the stub runs in
# a subshell and cannot increment a counter variable. Record calls in a file.
PROMPT_LOG="$TEST_TMP/prompt-calls.log"
: > "$PROMPT_LOG"
PROMPT_ANSWER=0
prompt_select() {
    echo "called" >> "$PROMPT_LOG"
    echo "$PROMPT_ANSWER"
}
prompt_calls() { wc -l < "$PROMPT_LOG" | tr -d ' '; }
rollback_snapshot() { :; }

# --- Ports free: nothing to skip, and the decision is still recorded ---
reset_proxy_config
HEADLESS="true"
STUB_PORT_80=""; STUB_PORT_443=""
proxy_detect >/dev/null 2>&1
assert_eq "false" "${CONFIG[proxy.external]:-<unset>}" \
    "free ports record proxy.external=false"
assert_eq "" "${CONFIG[proxy.detected]:-}" "free ports record no detected proxy"

# --- Headless with a bound port: Caddy must be skipped, not silently deployed ---
reset_proxy_config
HEADLESS="true"
STUB_PORT_80="$NGINX_80"; STUB_PORT_443="$NGINX_443"
proxy_detect >/dev/null 2>&1
assert_eq "nginx" "${CONFIG[proxy.detected]:-<unset>}" \
    "headless detection records proxy.detected for the wizard/report to read"
assert_eq "true" "${CONFIG[proxy.external]:-<unset>}" \
    "headless with a bound port sets proxy.external=true (skip Caddy)"
assert_eq "0" "$(prompt_calls)" "headless never prompts"

# --- Interactive, choice 0: generate snippets and skip Caddy ---
reset_proxy_config
HEADLESS="false"
PROMPT_ANSWER=0
STUB_PORT_80="$NGINX_80"; STUB_PORT_443=""
proxy_detect >/dev/null 2>&1
assert_eq "true" "${CONFIG[proxy.external]:-<unset>}" \
    "'skip Caddy' choice sets proxy.external=true"
assert_file_exists "$TEST_TMP/proxy/proxy-snippets/matrix-nginx.conf" \
    "'skip Caddy' choice writes the nginx snippet"

# --- Interactive, choice 1: alternate ports, Caddy still deployed ---
reset_proxy_config
HEADLESS="false"
PROMPT_ANSWER=1
STUB_PORT_80="$NGINX_80"; STUB_PORT_443=""
proxy_detect >/dev/null 2>&1
assert_eq "false" "${CONFIG[proxy.external]:-<unset>}" \
    "'alternate ports' choice keeps Caddy (proxy.external=false)"
assert_eq "8080" "${CONFIG[caddy.http_port]:-<unset>}" "alternate HTTP port recorded"
assert_eq "8443" "${CONFIG[caddy.https_port]:-<unset>}" "alternate HTTPS port recorded"

# --- The alternate ports reach the compose renderer ---
declare -A alt_vars=()
_compose_build_vars alt_vars
assert_eq "8080" "${alt_vars[CADDY_HTTP_PORT]:-<unset>}" \
    "alternate HTTP port reaches the compose vars"
assert_eq "8443" "${alt_vars[CADDY_HTTPS_PORT]:-<unset>}" \
    "alternate HTTPS port reaches the compose vars"
assert_eq "80" "${alt_vars[PORT_HTTP]:-<unset>}" \
    "container-side HTTP port is unchanged by the host-side override"

# Default (no alternate ports chosen) still publishes 80/443.
reset_proxy_config
declare -A default_vars=()
_compose_build_vars default_vars
assert_eq "80" "${default_vars[CADDY_HTTP_PORT]:-<unset>}" "CADDY_HTTP_PORT defaults to 80"
assert_eq "443" "${default_vars[CADDY_HTTPS_PORT]:-<unset>}" "CADDY_HTTPS_PORT defaults to 443"

# --- Second invocation must not re-prompt ---
# setup.sh runs proxy_detect as a phase and wizard_step_proxy runs it again;
# without a guard the admin answers the same menu twice and the second answer
# silently wins.
reset_proxy_config
HEADLESS="false"
PROMPT_ANSWER=0
STUB_PORT_80="$NGINX_80"; STUB_PORT_443=""
proxy_detect >/dev/null 2>&1
first_calls="$(prompt_calls)"
proxy_detect >/dev/null 2>&1
assert_eq "$first_calls" "$(prompt_calls)" "proxy_detect does not prompt twice for the same run"
assert_eq "true" "${CONFIG[proxy.external]:-<unset>}" "the first decision survives the second call"

# =====================================================================
# compose_assemble honours the skip-Caddy decision
# =====================================================================
# Fragment selection is the consumer of CONFIG[proxy.external]; assert on the
# assembled file rather than on the condition so the test survives a refactor.
COMPOSE_CMD=""              # skip `compose config` validation (no podman here)
declare -ga BRIDGES_ENABLED=()

assemble_into() {
    local dir="$1"
    mkdir -p "$dir"
    CONFIG["install_dir"]="$dir"
    compose_assemble >/dev/null 2>&1
    cat "$dir/podman-compose.yml"
}

reset_proxy_config
CONFIG["coturn.enabled"]="false"
CONFIG["proxy.external"]="false"
assert_match "caddy:" "$(assemble_into "$TEST_TMP/with-caddy")" \
    "compose includes the caddy service by default"

reset_proxy_config
CONFIG["coturn.enabled"]="false"
CONFIG["proxy.external"]="true"
assert_no_match "caddy:" "$(assemble_into "$TEST_TMP/no-caddy")" \
    "compose omits the caddy service when an external proxy handles HTTPS"

# The alternate-ports choice has to reach the published port mapping: only the
# host side moves, so Caddy still listens on 80/443 inside the container and the
# Caddyfile needs no changes.
reset_proxy_config
CONFIG["coturn.enabled"]="false"
CONFIG["proxy.external"]="false"
CONFIG["caddy.http_port"]="8080"
CONFIG["caddy.https_port"]="8443"
alt_compose="$(assemble_into "$TEST_TMP/alt-ports")"
assert_match '"8080:80"' "$alt_compose" "compose publishes Caddy's HTTP port on the alternate host port"
assert_match '"8443:443"' "$alt_compose" "compose publishes Caddy's HTTPS port on the alternate host port"

reset_proxy_config
CONFIG["coturn.enabled"]="false"
CONFIG["proxy.external"]="false"
default_compose="$(assemble_into "$TEST_TMP/default-ports")"
assert_match '"80:80"' "$default_compose" "compose publishes 80:80 by default"
assert_match '"443:443"' "$default_compose" "compose publishes 443:443 by default"

test_report
