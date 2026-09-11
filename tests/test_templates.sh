#!/usr/bin/env bash
# Tests for template rendering (lib/01_utils.sh template_render)
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"

setup_test_tmp

# --- Local assertions ---

# Fixed-string counterpart to assert_file_contains.
assert_file_lacks() {
    local file="$1"
    local pattern="$2"
    local description="${3:-file lacks pattern}"

    _TEST_NUM=$((_TEST_NUM + 1))

    # A missing file has no pattern in it, so the naive check passes and hides
    # the more serious failure. Score it as a failure instead.
    if [[ ! -f "$file" ]]; then
        echo "not ok $_TEST_NUM - $description"
        echo "#   file not found: $file"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
        return
    fi

    if grep -qF -- "$pattern" "$file" 2>/dev/null; then
        echo "not ok $_TEST_NUM - $description"
        echo "#   file: $file"
        echo "#   unwanted pattern found: $pattern"
        grep -nF -- "$pattern" "$file" | sed 's/^/#   /'
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    else
        echo "ok $_TEST_NUM - $description"
    fi
}

# PyYAML matches what Synapse itself uses (yaml.safe_load). Without it, fall
# back to checking that every column-0 line is a comment or a mapping key —
# enough to catch a leaked marker or placeholder, which always sits at column 0.
if python3 -c 'import yaml' 2>/dev/null; then
    _YAML_CHECK="pyyaml"
else
    _YAML_CHECK="structural"
    echo "# PyYAML unavailable: using a column-0 structural check instead"
fi

assert_yaml_loads() {
    local file="$1"
    local description="${2:-file is loadable YAML}"

    _TEST_NUM=$((_TEST_NUM + 1))

    # The structural fallback below reads nothing from a missing file and so
    # would call it valid. Fail first.
    if [[ ! -f "$file" ]]; then
        echo "not ok $_TEST_NUM - $description"
        echo "#   file not found: $file"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
        return
    fi

    local err=""
    local rc=0
    if [[ "$_YAML_CHECK" == "pyyaml" ]]; then
        err=$(python3 -c '
import sys, yaml
try:
    yaml.safe_load(open(sys.argv[1]))
except yaml.YAMLError as exc:
    print(exc)
    sys.exit(1)
' "$file" 2>&1) || rc=$?
    else
        err=$(awk '/^[^[:space:]#]/ && !/^[A-Za-z_][A-Za-z0-9_]*:/ { print FILENAME ":" NR ": " $0 }' "$file")
        if [[ -n "$err" ]]; then
            rc=1
        fi
    fi

    if (( rc == 0 )); then
        echo "ok $_TEST_NUM - $description"
    else
        echo "not ok $_TEST_NUM - $description"
        echo "#   file: $file"
        printf '%s\n' "$err" | sed 's/^/#   /'
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
}

# --- Test: simple variable substitution ---
cat > "$TEST_TMP/simple.tpl" << 'EOF'
server_name: "{{SERVER_NAME}}"
port: {{PORT}}
EOF

declare -A vars=([SERVER_NAME]="example.com" [PORT]="8008")
template_render "$TEST_TMP/simple.tpl" "$TEST_TMP/simple.out" vars

assert_file_contains "$TEST_TMP/simple.out" 'server_name: "example.com"' "variable substitution: string"
assert_file_contains "$TEST_TMP/simple.out" 'port: 8008' "variable substitution: number"

# --- Test: conditional blocks (true) ---
cat > "$TEST_TMP/cond.tpl" << 'EOF'
base config
{{#FEDERATION}}
federation_enabled: true
{{/FEDERATION}}
{{#METRICS}}
metrics_port: 9000
{{/METRICS}}
end config
EOF

declare -A vars=([FEDERATION]="true" [METRICS]="false")
template_render "$TEST_TMP/cond.tpl" "$TEST_TMP/cond.out" vars

assert_file_contains "$TEST_TMP/cond.out" "federation_enabled: true" "conditional block included when true"
assert_file_contains "$TEST_TMP/cond.out" "base config" "non-conditional content preserved"
assert_file_contains "$TEST_TMP/cond.out" "end config" "content after conditionals preserved"

assert_file_lacks "$TEST_TMP/cond.out" "metrics_port" "false conditional block removed"

# --- Test: multiple variables in same line ---
cat > "$TEST_TMP/multi.tpl" << 'EOF'
url: "https://{{SUBDOMAIN}}.{{DOMAIN}}"
EOF

declare -A vars=([SUBDOMAIN]="chat" [DOMAIN]="example.com")
template_render "$TEST_TMP/multi.tpl" "$TEST_TMP/multi.out" vars

assert_file_contains "$TEST_TMP/multi.out" 'url: "https://chat.example.com"' "multiple vars in one line"

# --- Test: unmatched variables remain ---
cat > "$TEST_TMP/unmatched.tpl" << 'EOF'
known: {{KNOWN}}
unknown: {{UNKNOWN}}
EOF

declare -A vars=([KNOWN]="yes")
template_render "$TEST_TMP/unmatched.tpl" "$TEST_TMP/unmatched.out" vars

assert_file_contains "$TEST_TMP/unmatched.out" "known: yes" "known var replaced"
assert_file_contains "$TEST_TMP/unmatched.out" "{{UNKNOWN}}" "unknown var left as-is"

# --- Test: special chars in values ---
cat > "$TEST_TMP/special.tpl" << 'EOF'
password: "{{PASSWORD}}"
EOF

declare -A vars=([PASSWORD]='p@ss/w0rd')
template_render "$TEST_TMP/special.tpl" "$TEST_TMP/special.out" vars

assert_file_contains "$TEST_TMP/special.out" 'password: "p@ss/w0rd"' "special chars in value preserved"

# --- Test: all compose templates are valid YAML-ish ---
for tpl in "$PROJECT_DIR"/templates/compose/*.yml; do
    _TEST_NUM=$((_TEST_NUM + 1))
    if [[ -s "$tpl" ]]; then
        echo "ok $_TEST_NUM - compose template exists and non-empty: $(basename "$tpl")"
    else
        echo "not ok $_TEST_NUM - compose template missing or empty: $(basename "$tpl")"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
done

# --- Test: all config templates exist ---
for tpl in homeserver.synapse.yaml.tpl homeserver.dendrite.yaml.tpl Caddyfile.tpl turnserver.conf.tpl log.config.tpl; do
    assert_file_exists "$PROJECT_DIR/templates/configs/$tpl" "config template exists: $tpl"
done

# --- Test: conditional block whose key is absent from the vars array ---
# An absent key is falsy: its block goes, markers and all. The renderer used to
# loop over the vars array, so a key nobody set was never visited and its
# markers survived into the output.
cat > "$TEST_TMP/absent.tpl" << 'EOF'
before
{{#NEVER_SET}}
leaked: true
{{/NEVER_SET}}
after
EOF

declare -A vars=([OTHER]="true")
template_render "$TEST_TMP/absent.tpl" "$TEST_TMP/absent.out" vars

assert_file_contains "$TEST_TMP/absent.out" "before" "absent conditional: content before block kept"
assert_file_contains "$TEST_TMP/absent.out" "after" "absent conditional: content after block kept"
assert_file_lacks "$TEST_TMP/absent.out" "leaked" "absent conditional: block body removed"
assert_file_lacks "$TEST_TMP/absent.out" "{{" "absent conditional: markers removed"

# --- Test: shipped homeserver configs render to loadable YAML ---
# Synapse reads homeserver.yaml with yaml.safe_load, so a leaked marker at
# column 0 crashloops the container behind a 180s deploy timeout. Render the
# real templates through the real code path for every registration policy.
source "$LIB_DIR/12_homeserver.sh"

# The rollback journal is not under test here.
rollback_snapshot() { :; }

_render_homeserver() {
    local hs_type="$1" policy="$2" outdir="$3" webclient="${4-element}"

    CONFIG=()
    CONFIG["domain.name"]="example.com"
    CONFIG["homeserver.type"]="$hs_type"
    CONFIG["install_dir"]="$outdir"
    CONFIG["webclient.type"]="$webclient"
    CONFIG["secrets.registration_shared_secret"]="reg-shared-secret"
    CONFIG["secrets.macaroon_secret_key"]="macaroon-secret"
    CONFIG["secrets.form_secret"]="form-secret"
    CONFIG["secrets.postgres_password"]="pg-password"
    CONFIG["secrets.coturn_secret"]="coturn-secret"
    if [[ -n "$policy" ]]; then
        CONFIG["registration.policy"]="$policy"
    fi

    mkdir -p "$outdir/config" "$outdir/data"
    # log_substep/log_success write to stdout; errors go to stderr and stay.
    "_homeserver_${hs_type}" "$outdir/config" "$outdir/data" > /dev/null
}

for policy in "" closed invite-only open-email open-captcha; do
    label="${policy:-unset-default}"

    out_dir="$TEST_TMP/hs-synapse-$label"
    _render_homeserver synapse "$policy" "$out_dir"
    assert_yaml_loads "$out_dir/config/homeserver.yaml" \
        "synapse config is loadable YAML: registration policy '$label'"
    assert_file_lacks "$out_dir/config/homeserver.yaml" "{{" \
        "synapse config has no unrendered placeholders: registration policy '$label'"

    out_dir="$TEST_TMP/hs-dendrite-$label"
    _render_homeserver dendrite "$policy" "$out_dir"
    assert_yaml_loads "$out_dir/config/dendrite.yaml" \
        "dendrite config is loadable YAML: registration policy '$label'"
    assert_file_lacks "$out_dir/config/dendrite.yaml" "{{" \
        "dendrite config has no unrendered placeholders: registration policy '$label'"
done

# --- Test: synapse config with no web client deployed ---
# web_client_location must be omitted entirely, not point at a subdomain that
# nothing serves.
_render_homeserver synapse "invite-only" "$TEST_TMP/hs-synapse-no-webclient" ""

assert_yaml_loads "$TEST_TMP/hs-synapse-no-webclient/config/homeserver.yaml" \
    "synapse config is loadable YAML: no web client"
assert_file_lacks "$TEST_TMP/hs-synapse-no-webclient/config/homeserver.yaml" "{{" \
    "synapse config has no unrendered placeholders: no web client"
assert_file_lacks "$TEST_TMP/hs-synapse-no-webclient/config/homeserver.yaml" "web_client_location" \
    "synapse config omits web_client_location when no web client is deployed"

# --- Test: a Synapse install renders log.config ---
# templates/compose/synapse.yml bind-mounts <install_dir>/config/log.config into
# the container, and homeserver.yaml points Synapse at the container-side path.
# Nothing but this render creates the host file. podman-run(1), --volume: "If
# the source does not exist, Podman returns an error. Users must pre-create the
# source files or directories."
logcfg_dir="$TEST_TMP/hs-synapse-logconfig"
_render_homeserver synapse "invite-only" "$logcfg_dir"

# Walk the chain the install actually uses instead of restating the paths here:
# homeserver.yaml names the container path, the compose fragment says which host
# file lands there, and that host file is what must exist.
hs_log_config=$(sed -n 's/^log_config: *"\(.*\)" *$/\1/p' "$logcfg_dir/config/homeserver.yaml" | head -1)
assert_ne "" "$hs_log_config" "homeserver.yaml names a log_config path"

logcfg_src=$(grep -F ":${hs_log_config}:" "$PROJECT_DIR/templates/compose/synapse.yml" \
    | sed 's/^ *- *//; s/:.*//' || true)
assert_ne "" "$logcfg_src" "compose fragment bind-mounts a host file at $hs_log_config"

logcfg_host="${logcfg_src/'{{INSTALL_DIR}}'/$logcfg_dir}"
assert_true "log.config exists at the compose bind-mount source" test -f "$logcfg_host"

assert_file_lacks "$logcfg_host" "{{" "rendered log.config has no unsubstituted placeholders"
assert_yaml_loads "$logcfg_host" "rendered log.config is loadable YAML"

# No secrets in it, and podman-run(1) notes that with a user namespace in use
# "the UID and GID in the container may correspond to another UID and GID on the
# host", so the container's reader is not the owner. Sibling turnserver.conf is
# 0640 only because it carries the TURN shared secret (lib/14_coturn.sh).
logcfg_mode=$(stat -c '%a' "$logcfg_host" 2>/dev/null || echo "no-file")
assert_eq "644" "$logcfg_mode" "log.config is mode 644"

# The file Synapse writes must land in the directory the compose fragment mounts
# back out to the host, or the fail2ban jail tails a path that never appears.
log_filename=$(sed -n 's/^[[:space:]]*filename:[[:space:]]*//p' "$logcfg_host" 2>/dev/null | head -1 || true)
assert_ne "" "$log_filename" "rendered log.config names a log file"

log_dir_ctr="${log_filename%/*}"
logdir_src=$(grep -F ":${log_dir_ctr:-/nonexistent}" "$PROJECT_DIR/templates/compose/synapse.yml" \
    | sed 's/^ *- *//; s/:.*//' || true)
logdir_host="${logdir_src/'{{INSTALL_DIR}}'/$logcfg_dir}"

assert_true "the log directory named by log.config is created by the install" test -d "$logdir_host"
assert_eq "$logcfg_dir/data/logs/homeserver.log" "$logdir_host/${log_filename##*/}" \
    "log.config resolves to the host path the fail2ban jail tails (lib/10_hardening.sh)"

# --- Test: log.config is journalled for rollback ---
# homeserver.yaml is snapshotted so a failed install backs it out; log.config is
# written by the same phase into the same directory.
rollback_journal="$TEST_TMP/rollback-journal"
: > "$rollback_journal"
rollback_snapshot() { printf '%s\n' "$3" >> "$rollback_journal"; }

_render_homeserver synapse "invite-only" "$TEST_TMP/hs-synapse-journal"

rollback_snapshot() { :; }

assert_file_contains "$rollback_journal" "hs-synapse-journal/config/log.config" \
    "log.config is journalled for rollback"

# --- Test: a Dendrite install renders no Synapse log.config ---
# templates/compose/dendrite.yml mounts no such file, and the template is
# Synapse's Python logging schema.
dendrite_logcfg_dir="$TEST_TMP/hs-dendrite-logconfig"
_render_homeserver dendrite "invite-only" "$dendrite_logcfg_dir"

assert_false "dendrite install does not render a Synapse log.config" \
    test -e "$dendrite_logcfg_dir/config/log.config"

# --- Test: every shipped template has a render call that reaches it ---
# log.config.tpl was bind-mounted and referenced with no template_render call
# anywhere. Catch the next one by name. Only the two lines following a
# template_render count, so a template named in a comment does not vouch for
# itself the way log.config.tpl did in lib/10_hardening.sh.
rendered_manifest="$TEST_TMP/rendered-templates.txt"
grep -rhA2 'template_render' "$PROJECT_DIR/lib" \
    | grep -o 'templates/[a-z]*/[A-Za-z0-9._-]*\.tpl' | sort -u > "$rendered_manifest"

for tpl in "$PROJECT_DIR"/templates/configs/*.tpl "$PROJECT_DIR"/templates/hardening/*.tpl; do
    tpl_rel="${tpl#"$PROJECT_DIR"/}"
    assert_true "a template_render call renders $tpl_rel" \
        grep -qxF "$tpl_rel" "$rendered_manifest"
done

# =====================================================================
# An unusable template is reported, not fatal
#
# template_render read its input with `content=$(<"$input")`. bash(1) under
# COMMAND SUBSTITUTION calls `$(< file)` "the equivalent but faster" form of
# `$(cat file)`, but the two are not equivalent when the open fails: the
# redirection form takes the whole shell down. bash(1) under `set -e` says the
# shell does not exit when the failing command is "part of any command executed
# in a && or || list except the command following the final && or ||", and that
# holds for an ordinary failure inside a function body. It does not hold here,
# so every `template_render ... || { log_error ...; return 1; }` guard in lib/
# was unreachable and setup.sh died mid-phase with only bash's own message.
# =====================================================================

# This has to run in a child shell. The failure mode is the *whole shell*
# exiting, and running the call inside a command substitution would confine
# that to the substitution's subshell, so the assertion would pass without
# proving anything. The sentinel printed after the call is the real evidence.
render_in_child() {
    local template="$1"
    local output="$2"

    cat > "$TEST_TMP/render_child.sh" << CHILD
set -euo pipefail
source "$PROJECT_DIR/tests/test_utils.sh"

declare -A vars=([NAME]="value")
rc=0
template_render "$template" "$output" vars || rc=\$?
printf 'CALLER_SURVIVED rc=%s\n' "\$rc"
CHILD

    bash "$TEST_TMP/render_child.sh" 2>&1 || true
}

# --- Test: a missing template ---
missing_out=$(render_in_child "$TEST_TMP/no-such-template.tpl" "$TEST_TMP/missing.out")

assert_match "CALLER_SURVIVED" "$missing_out" \
    "a missing template does not terminate the caller"
assert_match "CALLER_SURVIVED rc=1" "$missing_out" \
    "a missing template makes template_render return non-zero"
assert_match "no-such-template.tpl" "$missing_out" \
    "a missing template is named in the error"
assert_false "a missing template writes no output file" \
    test -e "$TEST_TMP/missing.out"

# --- Test: an unreadable template ---
# Mode 000 is readable by root, so the check would pass vacuously there.
printf 'name: {{NAME}}\n' > "$TEST_TMP/unreadable.tpl"
chmod 000 "$TEST_TMP/unreadable.tpl"

if [[ $EUID -eq 0 ]]; then
    skip_test "an unreadable template does not terminate the caller (running as root)"
    skip_test "an unreadable template makes template_render return non-zero (running as root)"
    skip_test "an unreadable template writes no output file (running as root)"
else
    unreadable_out=$(render_in_child "$TEST_TMP/unreadable.tpl" "$TEST_TMP/unreadable.out")

    assert_match "CALLER_SURVIVED" "$unreadable_out" \
        "an unreadable template does not terminate the caller"
    assert_match "CALLER_SURVIVED rc=1" "$unreadable_out" \
        "an unreadable template makes template_render return non-zero"
    assert_false "an unreadable template writes no output file" \
        test -e "$TEST_TMP/unreadable.out"
fi
chmod 644 "$TEST_TMP/unreadable.tpl"

# --- Test: a directory where a template was expected ---
# `$(<dir)` opens the directory, reads nothing and reports no error, so this
# path used to return 0 after rendering the template as nothing — the caller
# went on to write an empty config and call the phase a success.
mkdir -p "$TEST_TMP/a-directory.tpl"
dir_out=$(render_in_child "$TEST_TMP/a-directory.tpl" "$TEST_TMP/directory.out")

assert_match "CALLER_SURVIVED rc=1" "$dir_out" \
    "a directory in place of a template makes template_render return non-zero"
assert_false "a directory in place of a template writes no output file" \
    test -e "$TEST_TMP/directory.out"

# --- Test: reading a template preserves the content byte for byte ---
# Pins the read semantics the fix must not change. Command substitution deletes
# trailing newlines (bash(1), COMMAND SUBSTITUTION) and the final `echo` puts
# exactly one back, so all three of these render to the same trailing byte.
declare -A pin_vars=([V]="x")

printf 'a: {{V}}\n\n\n' > "$TEST_TMP/pin-trailing.tpl"
printf 'a: {{V}}'       > "$TEST_TMP/pin-notrailing.tpl"
printf ''               > "$TEST_TMP/pin-empty.tpl"

template_render "$TEST_TMP/pin-trailing.tpl"   "$TEST_TMP/pin-trailing.out"   pin_vars
template_render "$TEST_TMP/pin-notrailing.tpl" "$TEST_TMP/pin-notrailing.out" pin_vars
template_render "$TEST_TMP/pin-empty.tpl"      "$TEST_TMP/pin-empty.out"      pin_vars

assert_eq "5" "$(stat -c '%s' "$TEST_TMP/pin-trailing.out")" \
    "trailing newlines in a template are stripped to one"
assert_eq "5" "$(stat -c '%s' "$TEST_TMP/pin-notrailing.out")" \
    "a template with no trailing newline gains exactly one"
assert_eq "1" "$(stat -c '%s' "$TEST_TMP/pin-empty.out")" \
    "an empty template renders a single newline"

teardown_test_tmp
test_report
