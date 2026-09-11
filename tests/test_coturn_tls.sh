#!/usr/bin/env bash
# Tests for the coturn TLS decision (lib/14_coturn.sh) and the two start paths
# that have to agree with it: the rootful Quadlet unit (lib/20_quadlet.sh) and
# the `podman run` fallback (lib/21_deploy.sh).
#
# turnserver.conf points `cert=`/`pkey=` at /etc/coturn/certs, which only
# exists in the container if the host certificate directory is mounted. A path
# that writes the cert lines without the mount produces a coturn that cannot
# start, so the decision and the mount are asserted together on every path.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/14_coturn.sh"
source "$LIB_DIR/20_quadlet.sh"
source "$LIB_DIR/21_deploy.sh"

setup_test_tmp

rollback_snapshot() { :; }
sleep() { :; }

# `systemctl start matrix-coturn` must fail so the fallback path is reached.
STUB_BIN="$TEST_TMP/stub_bin"
mkdir -p "$STUB_BIN"
export STUB_ARGV_JOINED="$TEST_TMP/podman.argv.joined"

cat > "$STUB_BIN/podman" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARGV_JOINED"
exit 0
STUB
cat > "$STUB_BIN/systemctl" << 'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$STUB_BIN/podman" "$STUB_BIN/systemctl"
PATH="$STUB_BIN:$PATH"

# Build an install tree and run coturn_setup over it. With $2 == "certs" the
# certificate pair turnserver.conf will reference is present on the host.
coturn_fixture() {
    local install_dir="$1" certs="${2:-none}"
    rm -rf "$install_dir"
    mkdir -p "$install_dir/config"
    local cert_dir="$install_dir/data/caddy/data/caddy/certificates"
    if [[ "$certs" == "certs" ]]; then
        mkdir -p "$cert_dir"
        printf 'cert\n'  > "$cert_dir/cert.pem"
        printf 'key\n'   > "$cert_dir/privkey.pem"
    fi

    declare -gA CONFIG=()
    CONFIG["domain.name"]="example.com"
    CONFIG["install_dir"]="$install_dir"
    CONFIG["coturn.enabled"]="true"
    CONFIG["secrets.coturn_secret"]="turnsecret"
    coturn_setup >/dev/null 2>&1
}

# --- Test: the TLS decision is published, not kept local ---
NO_TLS_DIR="$TEST_TMP/install-notls"
coturn_fixture "$NO_TLS_DIR"
assert_eq "false" "${CONFIG[coturn.tls]:-<unset>}" \
    "coturn.tls is published as false when no certificate pair exists"
assert_false "turnserver.conf carries no cert= line without certificates" \
    grep -q '^cert=' "$NO_TLS_DIR/config/turnserver.conf"

TLS_DIR="$TEST_TMP/install-tls"
coturn_fixture "$TLS_DIR" certs
assert_eq "true" "${CONFIG[coturn.tls]:-<unset>}" \
    "coturn.tls is published as true when the certificate pair is present"
assert_eq "$TLS_DIR/data/caddy/data/caddy/certificates" "${CONFIG[coturn.cert_dir]:-<unset>}" \
    "coturn.cert_dir names the host directory holding the pair"
assert_file_contains "$TLS_DIR/config/turnserver.conf" "cert=/etc/coturn/certs/cert.pem" \
    "turnserver.conf references the mounted certificate"

# A directory that exists but holds no usable pair must not enable TLS: that is
# Caddy's own store layout, where the files are named <domain>.crt/.key.
CADDY_ONLY_DIR="$TEST_TMP/install-caddy-store"
rm -rf "$CADDY_ONLY_DIR"
mkdir -p "$CADDY_ONLY_DIR/config" \
         "$CADDY_ONLY_DIR/data/caddy/data/caddy/certificates/acme-v02/example.com"
printf 'crt\n' > "$CADDY_ONLY_DIR/data/caddy/data/caddy/certificates/acme-v02/example.com/example.com.crt"
declare -gA CONFIG=()
CONFIG["domain.name"]="example.com"
CONFIG["install_dir"]="$CADDY_ONLY_DIR"
CONFIG["coturn.enabled"]="true"
coturn_setup >/dev/null 2>&1
assert_eq "false" "${CONFIG[coturn.tls]:-<unset>}" \
    "an existing but empty certificate directory does not enable TLS"

# --- Test: the Quadlet unit mounts what turnserver.conf references ---
QUADLET_DIR="$TEST_TMP/quadlet"
mkdir -p "$QUADLET_DIR"
export QUADLET_SYSTEM_DIR="$QUADLET_DIR"
UNIT="$QUADLET_DIR/matrix-coturn.container"

coturn_fixture "$TLS_DIR" certs
rm -f "$UNIT"
_quadlet_generate_coturn "$TLS_DIR" >/dev/null 2>&1
assert_file_contains "$UNIT" \
    "Volume=$TLS_DIR/data/caddy/data/caddy/certificates:/etc/coturn/certs:ro" \
    "the Quadlet unit mounts the certificate directory when TLS is on"

coturn_fixture "$NO_TLS_DIR"
rm -f "$UNIT"
_quadlet_generate_coturn "$NO_TLS_DIR" >/dev/null 2>&1
assert_file_exists "$UNIT" "the Quadlet unit is written with TLS off"
assert_false "the Quadlet unit mounts nothing at /etc/coturn/certs when TLS is off" \
    grep -q '/etc/coturn/certs' "$UNIT"

# --- Test: the podman run fallback mounts the same directory ---
coturn_fixture "$TLS_DIR" certs
: > "$STUB_ARGV_JOINED"
_deploy_start_coturn "$TLS_DIR" >/dev/null 2>&1
assert_file_contains "$STUB_ARGV_JOINED" \
    "-v $TLS_DIR/data/caddy/data/caddy/certificates:/etc/coturn/certs:ro" \
    "the podman run fallback mounts the certificate directory when TLS is on"

coturn_fixture "$NO_TLS_DIR"
: > "$STUB_ARGV_JOINED"
_deploy_start_coturn "$NO_TLS_DIR" >/dev/null 2>&1
assert_true "the podman run fallback still starts coturn with TLS off" \
    grep -q 'turnserver.conf' "$STUB_ARGV_JOINED"
assert_false "the podman run fallback mounts nothing at /etc/coturn/certs when TLS is off" \
    grep -q '/etc/coturn/certs' "$STUB_ARGV_JOINED"

# --- Test: a coturn that does not start is reported, not announced as started ---
# Every branch of the fallback ended in `|| true`, so "Coturn started" was
# printed whatever happened - including when podman was not installed.
cat > "$STUB_BIN/podman" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARGV_JOINED"
exit 125
STUB
chmod +x "$STUB_BIN/podman"

coturn_fixture "$NO_TLS_DIR"
: > "$STUB_ARGV_JOINED"
COTURN_RC=0
# Not in a command substitution: the function records its result in CONFIG, and
# a subshell would discard that.
_deploy_start_coturn "$NO_TLS_DIR" > "$TEST_TMP/coturn.out" 2>&1 || COTURN_RC=$?
COTURN_OUT="$(cat "$TEST_TMP/coturn.out")"
assert_no_match "Coturn started" "$COTURN_OUT" \
    "a failed start is not announced as a start"
assert_match "[Cc]oturn" "$COTURN_OUT" "the failure names coturn"
assert_eq "failed" "${CONFIG[deploy.coturn_result]:-<unset>}" \
    "the failure is recorded for the post-install report"

# Restore the succeeding stub for anything that follows.
cat > "$STUB_BIN/podman" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARGV_JOINED"
exit 0
STUB
chmod +x "$STUB_BIN/podman"

coturn_fixture "$NO_TLS_DIR"
: > "$STUB_ARGV_JOINED"
_deploy_start_coturn "$NO_TLS_DIR" >/dev/null 2>&1
assert_eq "started" "${CONFIG[deploy.coturn_result]:-<unset>}" \
    "a successful start is recorded as started"

teardown_test_tmp
test_report
