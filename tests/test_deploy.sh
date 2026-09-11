#!/usr/bin/env bash
# Tests for lib/21_deploy.sh — how the deploy phase reaches the homeserver.
#
# Both homeserver fragments declare `ports: []`, so nothing the homeserver
# serves is published to the host: Caddy reaches it over matrix-net (dns
# networking) or the shared namespace (pod networking). Every deploy-phase
# probe therefore has to run inside the container, and none of them may depend
# on a host port existing.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/21_deploy.sh"

setup_test_tmp

rollback_snapshot() { :; }

# Retry backoff must not put real seconds into the suite.
sleep() { :; }

# =====================================================================
# Stub harness
#
# `podman`, `curl` and `sudo` are replaced on PATH. curl is stubbed separately
# from podman so that "the probe ran on the host" and "the probe ran in the
# container" are distinguishable: a test that only counted podman calls would
# pass just as well if the code called both.
# =====================================================================
STUB_BIN="$TEST_TMP/stub_bin"
mkdir -p "$STUB_BIN"

export STUB_ARGV="$TEST_TMP/podman.argv"
export STUB_ARGV_JOINED="$TEST_TMP/podman.argv.joined"
export STUB_STDIN="$TEST_TMP/podman.stdin"
export STUB_CALLS="$TEST_TMP/podman.calls"
export STUB_EXIT_CODES="$TEST_TMP/podman.exitcodes"
export STUB_CURL_CALLS="$TEST_TMP/curl.calls"

cat > "$STUB_BIN/podman" << 'STUB'
#!/usr/bin/env bash
# Test stub for podman. Records the invocation and answers the two Synapse
# admin-API requests the deploy path makes, so the registration flow can run to
# completion without a homeserver.
printf 'call\n' >> "$STUB_CALLS"
printf '%s\n' "$@" >> "$STUB_ARGV"
printf '%s\n' "$*" >> "$STUB_ARGV_JOINED"
# Only drain stdin when there is a pipe on it; an unconditional cat would
# consume the test script's own stdin.
if [ -p /dev/stdin ]; then
    cat >> "$STUB_STDIN"
fi

calls=$(wc -l < "$STUB_CALLS")
rc=$(sed -n "${calls}p" "$STUB_EXIT_CODES" 2>/dev/null || true)
[[ -n "$rc" ]] || rc=$(tail -n1 "$STUB_EXIT_CODES" 2>/dev/null || echo 0)
[[ -n "$rc" ]] || rc=0

if [[ "$rc" -eq 0 ]]; then
    case "$*" in
        *"-X POST"*|*"--data @-"*) echo '{"user_id":"@admin:example.com"}' ;;
        *_synapse/admin/v1/register*) echo '{"nonce":"stub-nonce"}' ;;
        *) echo '{"versions":["v1.13"]}' ;;
    esac
fi
exit "$rc"
STUB
chmod +x "$STUB_BIN/podman"

cat > "$STUB_BIN/curl" << 'STUB'
#!/usr/bin/env bash
# Test stub for curl. Records that a host-side curl happened at all; the deploy
# path must not make one, because no homeserver port is published to the host.
printf '%s\n' "$*" >> "$STUB_CURL_CALLS"
exit 7   # curl's "failed to connect", which is what a real host probe would get
STUB
chmod +x "$STUB_BIN/curl"

cat > "$STUB_BIN/sudo" << 'STUB'
#!/usr/bin/env bash
# Test stub for sudo: runs the command in place so stdin still reaches it.
if [[ "${1:-}" == "-u" ]]; then
    shift 2
fi
[[ "${1:-}" == "--" ]] && shift
exec "$@"
STUB
chmod +x "$STUB_BIN/sudo"

PATH="$STUB_BIN:$PATH"

reset_stub() {
    : > "$STUB_ARGV"
    : > "$STUB_ARGV_JOINED"
    : > "$STUB_STDIN"
    : > "$STUB_CALLS"
    : > "$STUB_CURL_CALLS"
    printf '%s\n' "${1:-0}" > "$STUB_EXIT_CODES"
    shift || true
    local code
    for code in "$@"; do
        printf '%s\n' "$code" >> "$STUB_EXIT_CODES"
    done
}

stub_call_count() {
    wc -l < "$STUB_CALLS" | tr -d ' '
}

host_curl_count() {
    wc -l < "$STUB_CURL_CALLS" | tr -d ' '
}

assert_argv_has() {
    local needle="$1"
    local description="${2:-argv contains $needle}"

    _TEST_NUM=$((_TEST_NUM + 1))

    if grep -Fxq -- "$needle" "$STUB_ARGV" 2>/dev/null; then
        echo "ok $_TEST_NUM - $description"
    else
        echo "not ok $_TEST_NUM - $description"
        echo "#   argument not found: $needle"
        sed 's/^/#   argv: /' "$STUB_ARGV"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
}

configure_deploy() {
    CONFIG=()
    CONFIG["homeserver.type"]="${1:-synapse}"
    CONFIG["domain.name"]="example.com"
    CONFIG["install_dir"]="$TEST_TMP/install"
    CONFIG["matrix_user"]="matrix"
    CONFIG["admin.username"]="admin"
    CONFIG["admin.password"]="$ADMIN_PASS"
    CONFIG["secrets.registration_shared_secret"]="shared-secret-under-test"
    CONFIG["coturn.enabled"]="false"
    CONFIG["deploy.homeserver_timeout"]="6"
}

ADMIN_PASS="correct-horse-battery-staple"
TEMPLATES_DIR="$PROJECT_DIR/templates/compose"

# --- The container name must match the fragment that declares it ---
# The deploy phase addresses the homeserver by container name. If the name here
# and the `container_name:` in the fragment ever drift, every probe silently
# targets a container that does not exist.
for hs in synapse dendrite; do
    configure_deploy "$hs"
    declared=$(sed -n 's/^ *container_name: *//p' "$TEMPLATES_DIR/${hs}.yml")
    assert_eq "$declared" "$(_deploy_homeserver_container)" \
        "$hs: the deploy phase uses the container name ${hs}.yml declares"
done

# --- Readiness probe runs inside the container, never against a host port ---
for hs in synapse dendrite; do
    configure_deploy "$hs"
    reset_stub 0
    probe_rc=0
    _deploy_wait_for_homeserver "example.com" >/dev/null 2>&1 || probe_rc=$?

    assert_eq "0" "$probe_rc" "$hs: readiness probe succeeds when the homeserver answers"
    assert_eq "0" "$(host_curl_count)" "$hs: readiness probe makes no host-side curl"
    assert_argv_has "exec" "$hs: readiness probe uses podman exec"
    assert_argv_has "matrix-${hs}" "$hs: readiness probe targets the matrix-${hs} container"
    assert_argv_has "http://localhost:8008/_matrix/client/versions" \
        "$hs: readiness probe asks for the client versions endpoint"
done

# --- A homeserver that never answers still fails the phase ---
configure_deploy synapse
reset_stub 1
probe_rc=0
probe_out=$(_deploy_wait_for_homeserver "example.com" 2>&1) || probe_rc=$?
assert_ne "0" "$probe_rc" "readiness probe fails when the homeserver never answers"
assert_match "did not become ready" "$probe_out" \
    "readiness probe reports the timeout"

# --- The probe target does not depend on the compose networking mode ---
# Under `pod` networking the containers share a namespace and under `dns` they
# do not, but in neither case does the host see port 8008. A probe that works
# only in one mode would pass a default-configuration test and fail in the field.
for net in dns pod; do
    COMPOSE_NETWORKING="$net"
    configure_deploy synapse
    reset_stub 0
    _deploy_wait_for_homeserver "example.com" >/dev/null 2>&1 || true

    assert_eq "0" "$(host_curl_count)" \
        "$net networking: readiness probe makes no host-side curl"
    assert_argv_has "matrix-synapse" \
        "$net networking: readiness probe still targets the container"
done
COMPOSE_NETWORKING="dns"

# --- Post-deploy health checks use the same route ---
configure_deploy synapse
reset_stub 0
health_out=$(_deploy_health_checks "example.com" 2>&1) || true

assert_eq "0" "$(host_curl_count)" "health checks make no host-side curl"
assert_argv_has "http://localhost:8008/_matrix/client/versions" \
    "health checks probe the client API in the container"
assert_argv_has "http://localhost:8008/_matrix/federation/v1/version" \
    "health checks probe the federation API in the container"
assert_match "Client API: OK" "$health_out" "client API check reports success"

# --- The compose command reaches podman intact, whatever shape it has ---
# COMPOSE_CMD is a string: "podman compose" (two words) from podman v5+,
# "podman-compose" or an absolute virtualenv path otherwise. As an argument to
# run_as_user it has to be split explicitly - quoted whole, the shell looks for
# a binary literally named "podman compose".
configure_deploy synapse
COMPOSE_CMD="podman compose"
reset_stub 0
_deploy_start_services "$TEST_TMP/install" "$TEST_TMP/install/podman-compose.yml" >/dev/null 2>&1 || true
assert_argv_has "compose" "two-word compose command: podman receives the subcommand"
assert_argv_has "up" "two-word compose command: podman receives 'up'"
assert_file_contains "$STUB_ARGV_JOINED" "compose -f .* up -d" \
    "two-word compose command: the whole invocation survives the split"

# A single-binary compose tool must not be split into pieces.
COMPOSE_CMD="podman-compose"
reset_stub 0
: > "$STUB_ARGV_JOINED"
_deploy_start_services "$TEST_TMP/install" "$TEST_TMP/install/podman-compose.yml" >/dev/null 2>&1 || true
assert_false "single-binary compose command: no stray 'compose' argument is passed" \
    grep -q '^compose$' "$STUB_ARGV"
COMPOSE_CMD="podman compose"

# --- A failed client API check must fail the phase ---
# The health checks used to be advisory: whatever they found, the phase logged
# "deployed successfully" and the installer carried on to write a report saying
# the stack was up.
configure_deploy synapse
reset_stub 1
health_rc=0
health_out=$(_deploy_health_checks "example.com" 2>&1) || health_rc=$?
assert_ne "0" "$health_rc" "health checks fail when the client API does not answer"
assert_match "Client API: FAILED" "$health_out" "the failing check is named"

# Federation is reachable from outside as often as not, so it warns and the
# phase still succeeds — but it is still counted and reported.
configure_deploy synapse
CONFIG["federation.enabled"]="true"
# First probe (client API) succeeds, second (federation) fails.
reset_stub 0 1
health_rc=0
health_out=$(_deploy_health_checks "example.com" 2>&1) || health_rc=$?
assert_eq "0" "$health_rc" "a failing federation probe does not fail the phase"
assert_match "Federation API: FAILED" "$health_out" "the federation failure is reported"
assert_match "1/2 passed" "$health_out" "the summary counts what passed"

# --- Synapse admin registration reaches the homeserver the same way ---
# This is the step immediately after the readiness probe, and it has the same
# root cause: there is no host port to POST to.
configure_deploy synapse
reset_stub 0
admin_out=$(_deploy_create_admin "example.com" 2>&1) || true

assert_eq "0" "$(host_curl_count)" "admin registration makes no host-side curl"
assert_argv_has "matrix-synapse" "admin registration targets the matrix-synapse container"
assert_argv_has "http://localhost:8008/_synapse/admin/v1/register" \
    "admin registration posts to the in-container admin API"
assert_match "Admin account created" "$admin_out" "admin registration reports success"

# --- Registration secrets must still not reach argv ---
# The body travels on stdin (--data @-) and the HMAC is computed from the
# environment. Moving the request into the container must not undo that.
argv_joined=$(cat "$STUB_ARGV_JOINED")
assert_no_match "$ADMIN_PASS" "$argv_joined" \
    "the admin password never appears in podman argv"
assert_no_match "shared-secret-under-test" "$argv_joined" \
    "the registration shared secret never appears in podman argv"
assert_match "$ADMIN_PASS" "$(cat "$STUB_STDIN")" \
    "the registration body is delivered on stdin"

teardown_test_tmp
test_report
