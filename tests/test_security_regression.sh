#!/usr/bin/env bash
# Regression tests for the QA-fleet security/correctness fixes.
# Each test pins a specific remediation so it cannot silently regress.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/03_toml_parser.sh"
source "$LIB_DIR/04_config.sh"
source "$LIB_DIR/25_rollback.sh"
source "$LIB_DIR/08_secrets.sh"
source "$LIB_DIR/10_hardening.sh"
source "$LIB_DIR/16_bridges.sh"
source "$LIB_DIR/26_upgrade.sh"

# Stub state-changing helpers used by the libs under test.
rollback_snapshot() { :; }
rollback_snapshot_file() { :; }

# config_validate helpers (suppress the expected [ERROR] diagnostics on stderr)
assert_valid()   { _TEST_NUM=$((_TEST_NUM + 1)); if config_validate 2>/dev/null; then echo "ok $_TEST_NUM - $1"; else echo "not ok $_TEST_NUM - $1"; _TEST_FAILURES=$((_TEST_FAILURES + 1)); fi; }
assert_invalid() { _TEST_NUM=$((_TEST_NUM + 1)); if config_validate 2>/dev/null; then echo "not ok $_TEST_NUM - $1"; _TEST_FAILURES=$((_TEST_FAILURES + 1)); else echo "ok $_TEST_NUM - $1"; fi; }

# grep-based negative assertion: bash =~ anchors ^ and $ to the whole string,
# so an anchored pattern can never match a line inside a rendered file.
assert_file_lacks() {
    local file="$1" pattern="$2" description="$3"
    _TEST_NUM=$((_TEST_NUM + 1))
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "not ok $_TEST_NUM - $description"
        echo "#   file: $file"
        echo "#   pattern should be absent: $pattern"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    else
        echo "ok $_TEST_NUM - $description"
    fi
}

reset_valid_config() {
    declare -gA CONFIG=()
    HEADLESS="false"
    CONFIG[domain.name]="matrix.example.com"
    CONFIG[homeserver.type]="synapse"
    _config_apply_defaults
}

setup_test_tmp

# =====================================================================
# 1. Config validation — injection vectors are rejected at the source
# =====================================================================

# Baseline must pass, otherwise the negative tests prove nothing.
reset_valid_config
assert_valid "baseline default config is valid"

# matrix_user (eval/shell sink)
reset_valid_config; CONFIG[matrix_user]='evil; rm -rf /'
assert_invalid "matrix_user with shell metacharacters rejected"
reset_valid_config; CONFIG[matrix_user]='matrix_1'
assert_valid "valid matrix_user accepted"

# install_dir (path / shell sink)
reset_valid_config; CONFIG[install_dir]='relative/dir'
assert_invalid "relative install_dir rejected"
reset_valid_config; CONFIG[install_dir]='/opt/../etc'
assert_invalid "install_dir with traversal rejected"
reset_valid_config; CONFIG[install_dir]='/opt/matrix; touch x'
assert_invalid "install_dir with shell metacharacters rejected"
reset_valid_config; CONFIG[install_dir]='/opt/matrix'
assert_valid "valid absolute install_dir accepted"

# database.user / database.name (SQL identifier sink)
reset_valid_config; CONFIG[database.user]="syn'; DROP TABLE x;--"
assert_invalid "database.user with SQL metacharacters rejected"
reset_valid_config; CONFIG[database.name]="syn'apse"
assert_invalid "database.name with quote rejected"
reset_valid_config; CONFIG[database.user]="synapse"; CONFIG[database.name]="synapse"
assert_valid "valid database identifiers accepted"

# admin.username (JSON body sink)
reset_valid_config; CONFIG[admin.username]='bad"user'
assert_invalid "admin.username with JSON-breaking chars rejected"
reset_valid_config; CONFIG[admin.username]='alice'
assert_valid "valid admin.username accepted"

# admin.password placeholder blocklist
reset_valid_config; CONFIG[admin.password]='changeme-at-least-8-chars'
assert_invalid "placeholder admin.password rejected"
reset_valid_config; CONFIG[admin.password]='S7rong!example#pass'
assert_valid "strong admin.password accepted"

# bridges.enabled (path traversal -> source sink)
reset_valid_config; CONFIG[bridges.enabled]='../../tmp/payload'
assert_invalid "bridges.enabled traversal rejected"
reset_valid_config; CONFIG[bridges.enabled]='telegram,../evil'
assert_invalid "bridges.enabled with one bad entry rejected"
reset_valid_config; CONFIG[bridges.enabled]='telegram,discord'
assert_valid "valid bridges.enabled accepted"

# Ports — arithmetic-injection style value must be rejected WITHOUT evaluating
reset_valid_config; CONFIG[coturn.min_port]='abc'
assert_invalid "non-numeric coturn.min_port rejected"
reset_valid_config; CONFIG[coturn.min_port]='70000'
assert_invalid "out-of-range coturn.min_port rejected"
reset_valid_config; CONFIG[coturn.min_port]='60000'; CONFIG[coturn.max_port]='50000'
assert_invalid "coturn.min_port >= max_port rejected"
rm -f "$TEST_TMP/pwned_port"
reset_valid_config; CONFIG[coturn.min_port]="9[\$(touch '$TEST_TMP/pwned_port')]9"
assert_invalid "arithmetic-injection coturn.min_port rejected"
_TEST_NUM=$((_TEST_NUM + 1))
if [[ ! -e "$TEST_TMP/pwned_port" ]]; then echo "ok $_TEST_NUM - port validation did not evaluate injected command"; else echo "not ok $_TEST_NUM - port injection executed!"; _TEST_FAILURES=$((_TEST_FAILURES + 1)); fi

# media_retention.days arithmetic-injection guard
rm -f "$TEST_TMP/pwned_days"
reset_valid_config; CONFIG[media_retention.days]="9\$(touch '$TEST_TMP/pwned_days')"
assert_invalid "non-integer media_retention.days rejected"
_TEST_NUM=$((_TEST_NUM + 1))
if [[ ! -e "$TEST_TMP/pwned_days" ]]; then echo "ok $_TEST_NUM - media_retention validation did not evaluate injected command"; else echo "not ok $_TEST_NUM - media_retention injection executed!"; _TEST_FAILURES=$((_TEST_FAILURES + 1)); fi

# =====================================================================
# 2. get_user_home resolves via getent (no eval)
# =====================================================================
_cur_user=$(id -un)
_expected_home=$(getent passwd "$_cur_user" | cut -d: -f6)
assert_eq "$_expected_home" "$(get_user_home "$_cur_user")" "get_user_home matches getent for current user"
assert_false "get_user_home fails for a nonexistent user" get_user_home "no_such_user_xyzzy_42"

# =====================================================================
# 3. secrets_generate_all idempotency + 0600 permissions
# =====================================================================
declare -gA CONFIG=()
CONFIG[install_dir]="$TEST_TMP/secrets"
CONFIG[domain.name]="test.example.com"
CONFIG[secrets.mode]="env"
mkdir -p "$TEST_TMP/secrets"
secrets_generate_all >/dev/null 2>&1
pass1=$(grep '^POSTGRES_PASSWORD=' "$TEST_TMP/secrets/.env" | cut -d= -f2-)
secrets_generate_all >/dev/null 2>&1   # second run must preserve, not regenerate
pass2=$(grep '^POSTGRES_PASSWORD=' "$TEST_TMP/secrets/.env" | cut -d= -f2-)
assert_ne "" "$pass1" "secrets_generate_all wrote a postgres password"
assert_eq "$pass1" "$pass2" "secrets_generate_all is idempotent (preserves existing .env)"
assert_eq "600" "$(stat -c '%a' "$TEST_TMP/secrets/.env")" "generated .env is mode 0600"

# =====================================================================
# 3b. Re-run repopulates CONFIG[secrets.*], not just the environment
# Consumers (12_homeserver, 11_postgres, 14_coturn, 21_deploy) read CONFIG.
# Sourcing .env alone left them empty, rendering GENERATE_ME placeholders.
# =====================================================================
_rerun_dir="$TEST_TMP/secrets-rerun"
_rerun_env="$_rerun_dir/.env"
_rerun_pairs=(
    "secrets.registration_shared_secret:REGISTRATION_SHARED_SECRET"
    "secrets.macaroon_secret_key:MACAROON_SECRET_KEY"
    "secrets.form_secret:FORM_SECRET"
    "secrets.postgres_password:POSTGRES_PASSWORD"
    "secrets.coturn_secret:COTURN_SECRET"
    "secrets.redis_password:REDIS_PASSWORD"
)

declare -gA CONFIG=()
CONFIG[install_dir]="$_rerun_dir"
CONFIG[domain.name]="test.example.com"
CONFIG[secrets.mode]="env"
mkdir -p "$_rerun_dir"
secrets_generate_all >/dev/null 2>&1

# Simulate a second invocation of the installer: only .env survives, and
# CONFIG starts empty apart from the settings restored from the state file.
declare -gA CONFIG=()
CONFIG[install_dir]="$_rerun_dir"
CONFIG[domain.name]="test.example.com"
CONFIG[secrets.mode]="env"
secrets_generate_all >/dev/null 2>&1

for _entry in "${_rerun_pairs[@]}"; do
    _cfg_key="${_entry%%:*}"
    _env_var="${_entry#*:}"
    _env_val=$(grep "^${_env_var}=" "$_rerun_env" | cut -d= -f2- || true)
    assert_ne "" "${CONFIG[$_cfg_key]:-}" "re-run populates CONFIG[$_cfg_key]"
    assert_eq "$_env_val" "${CONFIG[$_cfg_key]:-}" "CONFIG[$_cfg_key] matches $_env_var in .env"
done

# A .env written by an older version that lacks one of the six must fail loudly
# rather than leave the CONFIG key silently empty.
_partial_dir="$TEST_TMP/secrets-partial"
mkdir -p "$_partial_dir"
grep -v '^REDIS_PASSWORD=' "$_rerun_env" > "$_partial_dir/.env"
unset REDIS_PASSWORD   # the earlier `set -a; source` exported it into this shell

declare -gA CONFIG=()
CONFIG[install_dir]="$_partial_dir"
CONFIG[domain.name]="test.example.com"
CONFIG[secrets.mode]="env"
_partial_rc=0
secrets_generate_all >/dev/null 2>&1 || _partial_rc=$?
assert_ne "0" "$_partial_rc" "incomplete .env makes secrets_generate_all fail, not return silently"
assert_eq "" "${CONFIG[secrets.redis_password]:-}" "incomplete .env does not fabricate a redis password"

# =====================================================================
# 4. _harden_nftables actually APPLIES the ruleset (fail-open fix)
# =====================================================================
declare -gA CONFIG=()
CONFIG[install_dir]="$TEST_TMP/hard"
CONFIG[federation.enabled]="true"
CURRENT_PHASE="hardening"
mkdir -p "$TEST_TMP/hard"
rm -f "$TEST_TMP/hard/nft.log"
nft() { echo "nft $*" >> "$TEST_TMP/hard/nft.log"; }       # stub: record invocation
systemctl() { :; }                                          # stub
_harden_nftables >/dev/null 2>&1
assert_file_exists "$TEST_TMP/hard/matrix-nftables.conf" "nftables rules file written"
assert_file_exists "$TEST_TMP/hard/nft.log" "nft was invoked (rules applied, not just written)"
assert_file_contains "$TEST_TMP/hard/nft.log" "matrix-nftables.conf" "nft applied the generated ruleset file"
unset -f nft systemctl

# =====================================================================
# 5. Bridge name guard rejects traversal / unknown plugins before source
# =====================================================================
declare -gA BRIDGE_NAMES=([telegram]="mautrix-telegram")
declare -ga BRIDGES_ENABLED=()
_bridge_setup_single "../etc/passwd" "$TEST_TMP" >/dev/null 2>&1 || true
assert_eq "0" "${#BRIDGES_ENABLED[@]}" "path-traversal bridge name not enabled"
_bridge_setup_single "totally_unknown_bridge" "$TEST_TMP" >/dev/null 2>&1 || true
assert_eq "0" "${#BRIDGES_ENABLED[@]}" "unknown bridge name not enabled"

# =====================================================================
# 6. Rollback execution path (FILE_CREATED / FILE_BACKUP / SYSCTL_SET)
# =====================================================================
declare -gA CONFIG=()
CONFIG[install_dir]="$TEST_TMP/rb"
mkdir -p "$TEST_TMP/rb"
rollback_init_manifest

# Restore the real snapshot recorder for this section (we stubbed it above).
unset -f rollback_snapshot
rollback_snapshot() {
    [[ -n "$MANIFEST_FILE" && -f "$MANIFEST_FILE" ]] || return 0
    echo "$(date +%s)|$1|$2|$3" >> "$MANIFEST_FILE"
}

touch "$TEST_TMP/rb/created.txt"
rollback_snapshot "p" "FILE_CREATED" "$TEST_TMP/rb/created.txt"

echo "original" > "$TEST_TMP/rb/orig.txt"
cp "$TEST_TMP/rb/orig.txt" "$TEST_TMP/rb/orig.txt.bak"
echo "modified" > "$TEST_TMP/rb/orig.txt"
rollback_snapshot "p" "FILE_BACKUP" "$TEST_TMP/rb/orig.txt.bak|$TEST_TMP/rb/orig.txt"

sysctl_calls="$TEST_TMP/rb/sysctl.log"
sysctl() { echo "sysctl $*" >> "$sysctl_calls"; }
rollback_snapshot "p" "SYSCTL_SET" "net.ipv4.tcp_syncookies|0"

rollback_execute_all >/dev/null 2>&1

_TEST_NUM=$((_TEST_NUM + 1))
if [[ ! -f "$TEST_TMP/rb/created.txt" ]]; then echo "ok $_TEST_NUM - FILE_CREATED removed on rollback"; else echo "not ok $_TEST_NUM - FILE_CREATED not removed"; _TEST_FAILURES=$((_TEST_FAILURES + 1)); fi
assert_eq "original" "$(cat "$TEST_TMP/rb/orig.txt")" "FILE_BACKUP restored original content"
assert_file_contains "$sysctl_calls" "net.ipv4.tcp_syncookies=0" "SYSCTL_SET restored previous value"
unset -f sysctl

# =====================================================================
# 7. Upgrade PG-major parse is digest-pinning aware
# =====================================================================
assert_eq "16" "$(_pg_major_from_image 'docker.io/postgres:16.14-alpine@sha256:abc123')" "pg major parsed from digest-pinned ref"
assert_eq "16" "$(_pg_major_from_image 'docker.io/postgres:16-alpine')" "pg major parsed from tag-only ref"
assert_eq "15" "$(_pg_major_from_image 'docker.io/postgres:15.6')" "pg major parsed from plain version tag"
assert_eq "" "$(_pg_major_from_image 'docker.io/postgres@sha256:deadbeef')" "digest-only ref yields empty (guard skipped, not errored)"

# =====================================================================
# 8. Hardening drop-ins come from templates/hardening/ and name real paths
# =====================================================================
HARDENING_TPL="$PROJECT_DIR/templates/hardening"

# Every template in the directory must have a call site. The directory sat
# unused while lib/10_hardening.sh carried divergent heredocs; this pins the
# wiring so the two cannot drift apart again.
for tpl in fail2ban-matrix.conf.tpl fail2ban-matrix-filter.conf.tpl \
           99-matrix-hardening.conf.tpl sysctl-matrix.conf.tpl; do
    assert_file_exists "$HARDENING_TPL/$tpl" "hardening template present: $tpl"
    assert_true "lib/10_hardening.sh renders $tpl" \
        grep -q "$tpl" "$LIB_DIR/10_hardening.sh"
done

declare -gA CONFIG=()
CONFIG[install_dir]="$TEST_TMP/harden"
CONFIG[federation.enabled]="true"
CURRENT_PHASE="hardening"
mkdir -p "$TEST_TMP/harden/data/logs"

f2b_jail="$TEST_TMP/harden/jail.conf"
f2b_filter="$TEST_TMP/harden/filter.conf"
_harden_fail2ban_write "$f2b_jail" "$f2b_filter" >/dev/null 2>&1

assert_file_exists "$f2b_jail" "fail2ban jail written"
assert_file_exists "$f2b_filter" "fail2ban filter written"

# The jail must tail the file Synapse actually writes. Synapse's logging config
# (templates/configs/log.config.tpl) names /data/logs/homeserver.log inside the
# container, and templates/compose/synapse.yml bind-mounts the host directory
# there — so the host path is <install_dir>/data/logs/homeserver.log, not
# <install_dir>/data/synapse/.
assert_file_contains "$f2b_jail" "logpath *= *$TEST_TMP/harden/data/logs/homeserver.log" \
    "jail logpath points at the bind-mounted Synapse log directory"
assert_false "jail does not tail the non-existent data/synapse/ path" \
    grep -q "data/synapse/homeserver.log" "$f2b_jail"

# Derive the expected directory from the compose fragment rather than repeating
# the literal, so moving the mount breaks this test instead of the deployment.
synapse_log_mount=$(grep -o '{{INSTALL_DIR}}/[^:]*:/data/logs' "$PROJECT_DIR/templates/compose/synapse.yml" | head -1)
synapse_log_host="${synapse_log_mount%%:*}"
synapse_log_host="${synapse_log_host/\{\{INSTALL_DIR\}\}/$TEST_TMP/harden}"
assert_file_contains "$f2b_jail" "logpath *= *$synapse_log_host/homeserver.log" \
    "jail logpath matches the host side of the compose log mount"

# Protection that already existed must survive the move to a template.
assert_file_contains "$f2b_jail" "^\[sshd\]" "jail file still carries the sshd jail"
assert_file_contains "$f2b_jail" "^\[matrix-synapse\]" "jail file carries the matrix-synapse jail"
assert_file_contains "$f2b_jail" "$PORT_FEDERATION" "jail still covers the federation port"

# The filter carries no template variables, so a byte-identical copy proves the
# template — not a heredoc — produced it.
assert_eq "$(cat "$HARDENING_TPL/fail2ban-matrix-filter.conf.tpl")" "$(cat "$f2b_filter")" \
    "fail2ban filter is the rendered template verbatim"

# The hardening phase runs four phases before homeserver_setup creates the log
# directory (setup.sh: hardening, then PostgreSQL, then Homeserver), so on a
# normal install fail2ban starts before the directory exists. fail2ban tolerates
# a missing log *file* — the pyinotify backend watches the parent directory for
# IN_CREATE (fail2ban/server/filterpyinotify.py, _addFileWatcher ->
# _addDirWatcher) and the polling backend keeps a __file404Cnt per path — but it
# cannot watch a directory that is not there. So the directory has to exist.
rm -rf "$TEST_TMP/harden/data/logs"
_harden_fail2ban_write "$TEST_TMP/harden/jail2.conf" "$TEST_TMP/harden/filter2.conf" >/dev/null 2>&1
assert_true "the fail2ban phase creates the log directory it tells fail2ban to watch" \
    test -d "$TEST_TMP/harden/data/logs"

# The rootless Synapse container writes that log as the matrix user, so the
# directory cannot be left root-owned like the rest of the install tree.
chown_log="$TEST_TMP/harden/chown.log"
: > "$chown_log"
chown() { echo "chown $*" >> "$chown_log"; }
rm -rf "$TEST_TMP/harden/data/logs"
CONFIG[matrix_user]="matrix"
_harden_fail2ban_write "$TEST_TMP/harden/jail2b.conf" "$TEST_TMP/harden/filter2b.conf" >/dev/null 2>&1
assert_file_contains "$chown_log" "matrix" "log directory is handed to the matrix user, not left root-owned"
assert_file_contains "$chown_log" "data/logs" "the chown targets the log directory"
unset -f chown

# A healthy install must produce no warning at all: one that fires every time
# teaches the operator to skip past it. chown is stubbed to succeed here — the
# real phase runs as root with the matrix user already created by user_setup,
# whereas this harness is neither.
chown() { :; }
f2b_warn=$(_harden_fail2ban_write "$TEST_TMP/harden/jail3.conf" "$TEST_TMP/harden/filter3.conf" 2>&1 >/dev/null)
assert_eq "" "$f2b_warn" "a healthy Synapse install produces no fail2ban warning"

# ...and the ownership warning is not decorative: it fires when chown fails.
chown() { return 1; }
rm -rf "$TEST_TMP/harden/data/logs"
f2b_warn=$(_harden_fail2ban_write "$TEST_TMP/harden/jail3b.conf" "$TEST_TMP/harden/filter3b.conf" 2>&1 >/dev/null)
assert_match "unable to write its log" "$f2b_warn" "a log directory that cannot be handed over is reported"
unset -f chown

# The genuine case: the directory cannot be created. A regular file where the
# install directory should be makes mkdir -p fail without needing root.
blocked="$TEST_TMP/harden-blocked"
: > "$blocked"
CONFIG[install_dir]="$blocked"
f2b_warn=$(_harden_fail2ban_write "$TEST_TMP/harden/jail4.conf" "$TEST_TMP/harden/filter4.conf" 2>&1 >/dev/null)
assert_match "[Cc]ould not create" "$f2b_warn" "a log directory that cannot be created is reported"
CONFIG[install_dir]="$TEST_TMP/harden"

# Dendrite logs to stdout only (templates/configs/homeserver.dendrite.yaml.tpl:
# 'logging: - type: std'), so it never writes the file this jail tails and the
# Synapse failregex could not match its format anyway. Shipping the jail anyway
# would be a control that cannot fire.
CONFIG[homeserver.type]="dendrite"
dendrite_jail="$TEST_TMP/harden/jail-dendrite.conf"
f2b_warn=$(_harden_fail2ban_write "$dendrite_jail" "$TEST_TMP/harden/filter-dendrite.conf" 2>&1 >/dev/null)
assert_file_lacks "$dendrite_jail" "^\[matrix-synapse\]" \
    "no matrix-synapse jail on a Dendrite install"
assert_file_contains "$dendrite_jail" "^\[sshd\]" \
    "the sshd jail is still installed on a Dendrite install"
assert_match "Dendrite" "$f2b_warn" "the operator is told why there is no Matrix jail"
CONFIG[homeserver.type]="synapse"
_harden_fail2ban_write "$f2b_jail" "$f2b_filter" >/dev/null 2>&1
assert_file_contains "$f2b_jail" "^\[matrix-synapse\]" "the matrix-synapse jail returns for Synapse"

# --- sshd drop-in and sysctl file come from their templates ---
ssh_conf="$TEST_TMP/harden/sshd.conf"
_harden_ssh_write "$ssh_conf" >/dev/null 2>&1
assert_file_contains "$ssh_conf" "^PasswordAuthentication no" "sshd drop-in disables password auth"
assert_file_contains "$ssh_conf" "^PermitRootLogin no" "sshd drop-in disables root login"
assert_file_contains "$ssh_conf" "^AuthenticationMethods publickey" "sshd drop-in requires publickey"
# The templates carry {{#...}} option blocks, so the rendered file is not a byte
# copy. What must hold is that everything outside those blocks survives
# untouched — that is what proves the template, and not a heredoc, produced it.
template_unconditional() {
    awk '/^\{\{#/ {skip=1; next} /^\{\{\//{skip=0; next} skip {next} {print}' "$1"
}
assert_eq "$(template_unconditional "$HARDENING_TPL/99-matrix-hardening.conf.tpl")" "$(cat "$ssh_conf")" \
    "sshd drop-in is the template's unconditional body, rendered"

sysctl_conf="$TEST_TMP/harden/sysctl.conf"
_harden_sysctl_write "$sysctl_conf" >/dev/null 2>&1
assert_file_contains "$sysctl_conf" "^net.ipv4.ip_unprivileged_port_start=80" \
    "sysctl file keeps the rootless low-port setting"
assert_file_contains "$sysctl_conf" "^net.ipv4.tcp_syncookies=1" "sysctl file keeps SYN cookies"
assert_eq "$(template_unconditional "$HARDENING_TPL/sysctl-matrix.conf.tpl")" "$(cat "$sysctl_conf")" \
    "sysctl file is the template's unconditional body, rendered"

# ip_unprivileged_port_start=80 is what lets rootless Caddy bind 80/443 for ACME.
# The cost is that any local login can bind ports 80-1023 and squat on one, so
# the operator meets that trade-off in the file itself, not only in the docs.
assert_file_contains "$sysctl_conf" "ip_unprivileged_port_start=80" \
    "the low-port setting is present (rootless Caddy needs it)"
assert_file_contains "$sysctl_conf" "80-1023" \
    "the rendered sysctl file names the range any local user can then bind"
assert_file_contains "$sysctl_conf" "shell account" \
    "the rendered sysctl file says what that means in practice"
assert_true "the low-port trade-off is documented in matrix-setup.example.toml" \
    grep -q "80-1023" "$PROJECT_DIR/config/matrix-setup.example.toml"

# =====================================================================
# 9. harden_mac reports the confinement actually in force
# =====================================================================
# The stack's main services run rootless (lib/21_deploy.sh starts compose as the
# matrix user), and Podman does not apply AppArmor confinement in rootless mode.
# Whatever this function prints, it must not claim protection it is not
# providing, and it must say something on a host with neither MAC system.
setsebool() { :; }

SELINUX_MODE="absent"; APPARMOR_ACTIVE="false"
mac_out=$(harden_mac 2>&1)
assert_ne "" "$mac_out" "harden_mac is not silent on a host with neither SELinux nor AppArmor"
assert_match "[Nn]either|not available|no .*(MAC|mandatory access)" "$mac_out" \
    "harden_mac names the no-MAC case explicitly"

SELINUX_MODE="absent"; APPARMOR_ACTIVE="true"
mac_out=$(harden_mac 2>&1)
assert_no_match "no custom profiles needed" "$mac_out" \
    "harden_mac no longer asserts that no profiles are needed"
assert_match "rootless" "$mac_out" \
    "harden_mac states why no custom profile is loaded for the rootless stack"

SELINUX_MODE="enforcing"; APPARMOR_ACTIVE="false"
mac_out=$(harden_mac 2>&1)
assert_match "SELinux" "$mac_out" "harden_mac still reports the SELinux path"
unset -f setsebool

# =====================================================================
# 10. Operator-settable hardening options reach the rendered artefacts
# =====================================================================
# Each option defaults to the behaviour a current install already has, so
# nothing changes for someone who upgrades without touching their config.
# Assertions parse the rendered file, not the template.
declare -gA CONFIG=()
CONFIG[install_dir]="$TEST_TMP/harden"
CURRENT_PHASE="hardening"
mkdir -p "$TEST_TMP/harden/data/logs"

# Render, then assert per line with grep: bash's =~ anchors ^ and $ to the whole
# string, so an anchored pattern can never match a line inside a rendered file.
SSH_OUT="$TEST_TMP/harden/sshd-opt.conf"
SYSCTL_OUT="$TEST_TMP/harden/sysctl-opt.conf"
render_ssh()    { _harden_ssh_write "$SSH_OUT" >/dev/null 2>&1; }
render_sysctl() { _harden_sysctl_write "$SYSCTL_OUT" "${1:-}" >/dev/null 2>&1; }

# --- SSH port forwarding: allowed by default, restricted only on request ---
_config_apply_defaults
assert_eq "true" "${CONFIG[hardening.ssh_tcp_forwarding]:-<unset>}" \
    "hardening.ssh_tcp_forwarding defaults to true (today's behaviour)"

CONFIG[hardening.ssh_tcp_forwarding]="true"
render_ssh
assert_file_lacks "$SSH_OUT" "AllowTcpForwarding" \
    "default sshd drop-in says nothing about TCP forwarding, leaving the operator's own setting alone"

CONFIG[hardening.ssh_tcp_forwarding]="false"
render_ssh
assert_file_contains "$SSH_OUT" "^AllowTcpForwarding no$" \
    "opting out writes AllowTcpForwarding no"
assert_file_contains "$SSH_OUT" "^PasswordAuthentication no$" \
    "the rest of the SSH drop-in is unaffected by the forwarding option"
CONFIG[hardening.ssh_tcp_forwarding]="true"

# --- IPv6 privacy addresses: off by default ---
assert_eq "false" "${CONFIG[hardening.ipv6_privacy]:-<unset>}" \
    "hardening.ipv6_privacy defaults to false (today's behaviour)"

render_sysctl
assert_file_lacks "$SYSCTL_OUT" "use_tempaddr" \
    "default sysctl file does not enable IPv6 privacy addresses"

CONFIG[hardening.ipv6_privacy]="true"
render_sysctl
assert_file_contains "$SYSCTL_OUT" "^net.ipv6.conf.all.use_tempaddr=2$" "opting in sets use_tempaddr on all interfaces"
assert_file_contains "$SYSCTL_OUT" "^net.ipv6.conf.default.use_tempaddr=2$" "opting in sets use_tempaddr as the interface default"
assert_file_contains "$SYSCTL_OUT" "^net.ipv4.tcp_syncookies=1$" "the rest of the sysctl file is unaffected by the IPv6 option"
CONFIG[hardening.ipv6_privacy]="false"

# --- conntrack table size: unset by default, and only written if the kernel
#     exposes the key (the nf_conntrack module may not be loaded) ---
assert_eq "" "${CONFIG[hardening.conntrack_max]:-}" \
    "hardening.conntrack_max defaults to unset (today's behaviour)"
render_sysctl
assert_file_lacks "$SYSCTL_OUT" "nf_conntrack_max" \
    "default sysctl file does not touch the conntrack table size"

conntrack_probe="$TEST_TMP/harden/nf_conntrack_max"
: > "$conntrack_probe"
CONFIG[hardening.conntrack_max]="131072"
render_sysctl "$conntrack_probe"
assert_file_contains "$SYSCTL_OUT" "^net.netfilter.nf_conntrack_max=131072$" \
    "conntrack_max is written when the kernel exposes the key"

rm -f "$conntrack_probe"
render_sysctl "$conntrack_probe"
assert_file_lacks "$SYSCTL_OUT" "nf_conntrack_max" \
    "conntrack_max is omitted when the kernel does not expose the key"
conntrack_warn=$(_harden_sysctl_write "$TEST_TMP/harden/sysctl-warn.conf" "$conntrack_probe" 2>&1 >/dev/null)
assert_match "conntrack" "$conntrack_warn" \
    "skipping conntrack_max is reported, not silently dropped"
CONFIG[hardening.conntrack_max]=""

# --- No unrendered markers leak into either artefact in any combination ---
for tcp in true false; do
    for privacy in true false; do
        CONFIG[hardening.ssh_tcp_forwarding]="$tcp"
        CONFIG[hardening.ipv6_privacy]="$privacy"
        for ct in "" "131072"; do
            CONFIG[hardening.conntrack_max]="$ct"
            : > "$conntrack_probe"
            render_ssh; render_sysctl "$conntrack_probe"
            assert_file_lacks "$SSH_OUT" "{{" \
                "no template markers leak into the sshd drop-in (tcp_forwarding=$tcp conntrack_max=${ct:-unset})"
            assert_file_lacks "$SYSCTL_OUT" "{{" \
                "no template markers leak into the sysctl file (ipv6_privacy=$privacy conntrack_max=${ct:-unset})"
        done
    done
done

teardown_test_tmp
test_report
