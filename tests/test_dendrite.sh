#!/usr/bin/env bash
# Tests for the Dendrite homeserver path: admin-account creation in
# lib/21_deploy.sh and the registration/TURN wiring in lib/12_homeserver.sh.
#
# Every fact about Dendrite asserted here is taken from Dendrite v0.14.1, the
# version pinned in DENDRITE_IMAGE:
#   - cmd/create-account/main.go        (flags, stdin password, exit on failure)
#   - Dockerfile                        (/usr/bin/create-account in the image)
#   - docs/administration/1_createusers.md
#   - setup/config/config_clientapi.go  (registration_disabled, client_api.turn)
#   - setup/config/config_global.go     (global has no `turn` key)
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/12_homeserver.sh"
source "$LIB_DIR/21_deploy.sh"

setup_test_tmp

# The rollback journal is not under test here.
rollback_snapshot() { :; }

# Retry backoff must not put real seconds into the suite.
sleep() { :; }

# =====================================================================
# Stub harness
#
# `podman` and `sudo` are replaced on PATH. The podman stub records argv one
# argument per line (so a flag can be matched exactly) plus a joined line (so a
# leaked credential can be searched for), and records stdin verbatim. It leaves
# proof it ran: a stub that is never reached is otherwise indistinguishable
# from a working dependency.
# =====================================================================
STUB_BIN="$TEST_TMP/stub_bin"
mkdir -p "$STUB_BIN"

export STUB_ARGV="$TEST_TMP/podman.argv"
export STUB_ARGV_JOINED="$TEST_TMP/podman.argv.joined"
export STUB_STDIN="$TEST_TMP/podman.stdin"
export STUB_ENV="$TEST_TMP/podman.env"
export STUB_CALLS="$TEST_TMP/podman.calls"
export STUB_SUDO_USER="$TEST_TMP/sudo.user"
export STUB_EXIT_CODES="$TEST_TMP/podman.exitcodes"

cat > "$STUB_BIN/podman" << 'STUB'
#!/usr/bin/env bash
# Test stub for podman. Records the invocation, then exits with the next code
# from STUB_EXIT_CODES (one per line, last value repeats).
printf 'call\n' >> "$STUB_CALLS"
printf '%s\n' "$@" >> "$STUB_ARGV"
printf '%s\n' "$*" >> "$STUB_ARGV_JOINED"
env >> "$STUB_ENV"
cat >> "$STUB_STDIN"

calls=$(wc -l < "$STUB_CALLS")
rc=$(sed -n "${calls}p" "$STUB_EXIT_CODES" 2>/dev/null || true)
[[ -n "$rc" ]] || rc=$(tail -n1 "$STUB_EXIT_CODES" 2>/dev/null || echo 0)
[[ -n "$rc" ]] || rc=0

if [[ "$rc" -eq 0 ]]; then
    # Real create-account logs the new account's access token on success.
    echo 'time="2026-09-10T00:00:00Z" level=info msg="Created account: admin (AccessToken: syt_c3R1Yg_TESTTOKEN_1)"' >&2
else
    echo 'time="2026-09-10T00:00:00Z" level=fatal msg="Failed to create the account: got HTTP 500 error from server"' >&2
fi
exit "$rc"
STUB
chmod +x "$STUB_BIN/podman"

cat > "$STUB_BIN/sudo" << 'STUB'
#!/usr/bin/env bash
# Test stub for sudo: records the target user, then runs the command in place
# so stdin still reaches it.
if [[ "${1:-}" == "-u" ]]; then
    printf '%s\n' "$2" >> "$STUB_SUDO_USER"
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
    : > "$STUB_ENV"
    : > "$STUB_CALLS"
    : > "$STUB_SUDO_USER"
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

# --- Local assertions ---

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

assert_file_lacks_fixed() {
    local file="$1"
    local needle="$2"
    local description="${3:-file lacks $needle}"

    _TEST_NUM=$((_TEST_NUM + 1))

    if grep -qF -- "$needle" "$file" 2>/dev/null; then
        echo "not ok $_TEST_NUM - $description"
        echo "#   file: $file"
        echo "#   unwanted string found: $needle"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    else
        echo "ok $_TEST_NUM - $description"
    fi
}

assert_lacks() {
    local haystack="$1"
    local needle="$2"
    local description="${3:-string lacks $needle}"

    _TEST_NUM=$((_TEST_NUM + 1))

    if [[ "$haystack" == *"$needle"* ]]; then
        echo "not ok $_TEST_NUM - $description"
        echo "#   unwanted string found: $needle"
        echo "#   in: $haystack"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    else
        echo "ok $_TEST_NUM - $description"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local description="${3:-string contains $needle}"

    _TEST_NUM=$((_TEST_NUM + 1))

    if [[ "$haystack" == *"$needle"* ]]; then
        echo "ok $_TEST_NUM - $description"
    else
        echo "not ok $_TEST_NUM - $description"
        echo "#   expected substring: $needle"
        echo "#   in: $haystack"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
}

# =====================================================================
# Admin-account creation (lib/21_deploy.sh)
# =====================================================================

ADMIN_PASS='p@ss w0rd"with$quotes\and\\backslash'

configure_dendrite_deploy() {
    CONFIG=()
    CONFIG["homeserver.type"]="dendrite"
    CONFIG["domain.name"]="example.com"
    CONFIG["install_dir"]="$TEST_TMP/install"
    CONFIG["matrix_user"]="matrix"
    CONFIG["admin.username"]="admin"
    CONFIG["admin.password"]="$ADMIN_PASS"
    CONFIG["secrets.registration_shared_secret"]="dendrite-shared-secret"
}

# --- Test: the happy path shells out to Dendrite's create-account ---
configure_dendrite_deploy
reset_stub 0
out=$(_deploy_create_admin "example.com" 2>&1) || true

assert_eq "1" "$(stub_call_count)" "dendrite: create-account invoked exactly once"
assert_argv_has "exec" "dendrite: uses podman exec"
assert_argv_has "matrix-dendrite" "dendrite: targets the matrix-dendrite container"
assert_argv_has "/usr/bin/create-account" "dendrite: runs /usr/bin/create-account"
assert_argv_has "-config" "dendrite: passes -config"
assert_argv_has "/etc/dendrite/dendrite.yaml" "dendrite: -config points at the in-container config path"
assert_argv_has "-username" "dendrite: passes -username"
assert_argv_has "admin" "dendrite: -username value is the configured localpart"
assert_argv_has "-admin" "dendrite: requests an admin account"
assert_argv_has "-passwordstdin" "dendrite: reads the password from stdin"
assert_argv_has "-i" "dendrite: podman exec keeps stdin open"

# --- Test: the password travels on stdin, never on argv ---
assert_eq "$ADMIN_PASS" "$(cat "$STUB_STDIN")" "dendrite: password delivered verbatim on stdin"
assert_file_lacks_fixed "$STUB_ARGV_JOINED" "$ADMIN_PASS" \
    "dendrite: admin password never reaches argv"
assert_file_lacks_fixed "$STUB_ARGV_JOINED" "-password " \
    "dendrite: the argv-exposing -password flag is not used"
assert_file_lacks_fixed "$STUB_ARGV_JOINED" "dendrite-shared-secret" \
    "dendrite: registration shared secret never reaches argv"
assert_file_lacks_fixed "$STUB_ENV" "$ADMIN_PASS" \
    "dendrite: admin password not exported into the child environment"
assert_file_lacks_fixed "$STUB_ENV" "dendrite-shared-secret" \
    "dendrite: shared secret not exported into the child environment"

# --- Test: the access token in create-account's output is not logged ---
assert_lacks "$out" "syt_c3R1Yg_TESTTOKEN_1" "dendrite: access token is not written to the log"
assert_lacks "$out" "$ADMIN_PASS" "dendrite: admin password is not written to the log"
assert_contains "$out" "Admin account created: @admin:example.com" \
    "dendrite: success is reported to the operator"

# --- Test: the container runs under the matrix user, not root ---
assert_eq "matrix" "$(head -n1 "$STUB_SUDO_USER")" \
    "dendrite: create-account runs as the matrix user"

# --- Test: a transient failure is retried ---
configure_dendrite_deploy
reset_stub 1 0
out=$(_deploy_create_admin "example.com" 2>&1) || true

assert_eq "2" "$(stub_call_count)" "dendrite: a failed attempt is retried"
assert_contains "$out" "Admin account created: @admin:example.com" \
    "dendrite: retry success is reported"

# --- Test: persistent failure is surfaced, not swallowed ---
configure_dendrite_deploy
reset_stub 1 1 1
rc=0
out=$(_deploy_create_admin "example.com" 2>&1) || rc=$?

assert_eq "3" "$(stub_call_count)" "dendrite: gives up after three attempts"
assert_contains "$out" "[WARN]" "dendrite: persistent failure raises a warning"
assert_contains "$out" "create-account" \
    "dendrite: failure names the Dendrite manual fallback command"
assert_lacks "$out" "register_new_matrix_user" \
    "dendrite: failure does not print the Synapse fallback command"
assert_lacks "$out" "$ADMIN_PASS" \
    "dendrite: the password is not echoed in the failure diagnostics"

# --- Test: no admin password means no container call at all ---
configure_dendrite_deploy
CONFIG["admin.password"]=""
reset_stub 0
out=$(_deploy_create_admin "example.com" 2>&1) || true

assert_eq "0" "$(stub_call_count)" "dendrite: no password, no create-account call"
assert_contains "$out" "skipping admin account creation" \
    "dendrite: skipping is reported"

# --- Test: the Synapse path does not use Dendrite's create-account ---
# Both paths now run inside the container via `podman exec`, so "reached podman
# at all" no longer distinguishes them. What matters is which binary is invoked.
CONFIG=()
CONFIG["homeserver.type"]="synapse"
CONFIG["domain.name"]="example.com"
CONFIG["admin.username"]="admin"
CONFIG["admin.password"]="$ADMIN_PASS"
CONFIG["secrets.registration_shared_secret"]="synapse-shared-secret"
reset_stub 0
out=$(_deploy_create_admin "example.com" 2>&1) || true

assert_file_lacks_fixed "$STUB_ARGV_JOINED" "create-account" \
    "synapse: admin creation does not use Dendrite's create-account"
assert_contains "$out" "register_new_matrix_user" \
    "synapse: fallback command is still the Synapse one"

# =====================================================================
# Dendrite configuration (lib/12_homeserver.sh + the config template)
# =====================================================================

_render_dendrite() {
    local policy="$1" outdir="$2" coturn="${3:-true}"

    CONFIG=()
    CONFIG["domain.name"]="example.com"
    CONFIG["homeserver.type"]="dendrite"
    CONFIG["install_dir"]="$outdir"
    CONFIG["coturn.enabled"]="$coturn"
    CONFIG["secrets.registration_shared_secret"]="reg-shared-secret"
    CONFIG["secrets.postgres_password"]="pg-password"
    CONFIG["secrets.coturn_secret"]="coturn-secret"
    [[ -n "$policy" ]] && CONFIG["registration.policy"]="$policy"

    mkdir -p "$outdir/config" "$outdir/data"
    _homeserver_dendrite "$outdir/config" "$outdir/data" > /dev/null
}

# Read a dotted path out of a rendered YAML file. Prints "<missing>" when the
# path does not exist, so an absent key is distinguishable from a false value.
yaml_path() {
    local file="$1" path="$2"
    python3 -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
node = doc
for part in sys.argv[2].split("."):
    if not isinstance(node, dict) or part not in node:
        print("<missing>")
        sys.exit(0)
    node = node[part]
print(node)
' "$file" "$path"
}

# --- Test: registration_disabled is the inverse of "registration enabled" ---
# Dendrite's client_api.registration_disabled is true to DISABLE registration
# (setup/config/config_clientapi.go). Writing the "enable" flag straight into
# it opens registration on exactly the closed and invite-only policies.
for policy in closed invite-only; do
    _render_dendrite "$policy" "$TEST_TMP/dendrite-$policy"
    assert_eq "True" \
        "$(yaml_path "$TEST_TMP/dendrite-$policy/config/dendrite.yaml" client_api.registration_disabled)" \
        "dendrite: registration_disabled is true for policy '$policy'"
done

for policy in open-email open-captcha; do
    _render_dendrite "$policy" "$TEST_TMP/dendrite-$policy"
    assert_eq "False" \
        "$(yaml_path "$TEST_TMP/dendrite-$policy/config/dendrite.yaml" client_api.registration_disabled)" \
        "dendrite: registration_disabled is false for policy '$policy'"
done

# The unset default is invite-only, so it must also be closed.
_render_dendrite "" "$TEST_TMP/dendrite-default"
assert_eq "True" \
    "$(yaml_path "$TEST_TMP/dendrite-default/config/dendrite.yaml" client_api.registration_disabled)" \
    "dendrite: registration_disabled is true when no policy is configured"

# --- Test: shared secret registration stays available regardless of policy ---
# create-account refuses to run without client_api.registration_shared_secret.
assert_eq "reg-shared-secret" \
    "$(yaml_path "$TEST_TMP/dendrite-closed/config/dendrite.yaml" client_api.registration_shared_secret)" \
    "dendrite: registration_shared_secret is set even on a closed server"

# --- Test: TURN is configured where Dendrite reads it ---
# TURN lives on ClientAPI (config_clientapi.go); Global has no `turn` key
# (config_global.go), so a turn block under `global` is silently ignored.
_render_dendrite "invite-only" "$TEST_TMP/dendrite-turn" true
turn_cfg="$TEST_TMP/dendrite-turn/config/dendrite.yaml"

assert_eq "coturn-secret" "$(yaml_path "$turn_cfg" client_api.turn.turn_shared_secret)" \
    "dendrite: turn_shared_secret is under client_api"
assert_eq "<missing>" "$(yaml_path "$turn_cfg" global.turn)" \
    "dendrite: no turn block under global, where Dendrite would ignore it"

# --- Test: TURN block disappears when Coturn is off ---
_render_dendrite "invite-only" "$TEST_TMP/dendrite-noturn" false
assert_eq "<missing>" \
    "$(yaml_path "$TEST_TMP/dendrite-noturn/config/dendrite.yaml" client_api.turn)" \
    "dendrite: no turn block when coturn is disabled"

teardown_test_tmp
test_report
