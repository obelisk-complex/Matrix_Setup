#!/usr/bin/env bash
# Tests for bridge registration: lib/16_bridges.sh + homeserver_add_appservice.
#
# A bridge that is deployed but not registered with the homeserver looks
# installed and does nothing, so "registered" has to mean the homeserver config
# changed, and a homeserver that cannot register one has to say so.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/12_homeserver.sh"
source "$LIB_DIR/16_bridges.sh"

setup_test_tmp

rollback_snapshot() { :; }
secrets_generate_bridge_tokens() {
    CONFIG["secrets.${1}_as_token"]="as-token-$1"
    CONFIG["secrets.${1}_hs_token"]="hs-token-$1"
}

INSTALL_DIR="$TEST_TMP/install"
CONFIG_DIR="$INSTALL_DIR/config"
APPSERVICE_DIR="$CONFIG_DIR/appservices"
mkdir -p "$APPSERVICE_DIR"

write_hs_config() {
    cat > "$CONFIG_DIR/homeserver.yaml" << 'YAML'
server_name: "example.com"
app_service_config_files: []
YAML
}

# --- Test: Synapse registration actually edits the homeserver config ---
declare -gA CONFIG=()
CONFIG["install_dir"]="$INSTALL_DIR"
CONFIG["homeserver.type"]="synapse"
write_hs_config
homeserver_add_appservice "/data/appservices/whatsapp-registration.yaml" >/dev/null 2>&1
assert_file_contains "$CONFIG_DIR/homeserver.yaml" \
    '  - "/data/appservices/whatsapp-registration.yaml"' \
    "synapse: the registration path is written into app_service_config_files"

# --- Test: a homeserver that cannot register one says so ---
CONFIG["homeserver.type"]="dendrite"
write_hs_config
ADD_RC=0
ADD_OUT="$(homeserver_add_appservice "/data/appservices/whatsapp-registration.yaml" 2>&1)" || ADD_RC=$?
assert_ne "0" "$ADD_RC" "dendrite: registering an appservice fails instead of no-opping"
assert_no_match "Registered appservice" "$ADD_OUT" \
    "dendrite: nothing claims the appservice was registered"
assert_false "dendrite: the homeserver config is left untouched" \
    grep -q 'whatsapp-registration' "$CONFIG_DIR/homeserver.yaml"

# --- Test: a plugin missing bridge_generate_registration gets no registration ---
# The plugins are sourced into the same shell, so a function defined by an
# earlier plugin is still defined when a later one is sourced: without an unset
# the later bridge is registered with the earlier bridge's YAML.
FAKE_BRIDGES="$TEST_TMP/bridges"
mkdir -p "$FAKE_BRIDGES"
cat > "$FAKE_BRIDGES/alpha.sh" << 'PLUGIN'
bridge_name() { echo "alpha"; }
bridge_description() { echo "Alpha bridge"; }
bridge_image() { echo "example.com/alpha:1"; }
bridge_requires_synapse() { return 0; }
bridge_generate_registration() { printf 'id: alpha\nas_token: %s\n' "$2" > "$1"; }
bridge_compose_fragment() { echo "  alpha:"; }
PLUGIN
cat > "$FAKE_BRIDGES/beta.sh" << 'PLUGIN'
bridge_name() { echo "beta"; }
bridge_description() { echo "Beta bridge"; }
bridge_image() { echo "example.com/beta:1"; }
bridge_requires_synapse() { return 0; }
bridge_compose_fragment() { echo "  beta:"; }
PLUGIN

declare -gA CONFIG=()
CONFIG["install_dir"]="$INSTALL_DIR"
CONFIG["homeserver.type"]="synapse"
CONFIG["domain.name"]="example.com"
CONFIG["bridges.enabled"]="alpha,beta"
write_hs_config
rm -f "$APPSERVICE_DIR"/*.yaml
SCRIPT_DIR="$TEST_TMP" bridges_setup >/dev/null 2>&1 || true

assert_file_exists "$APPSERVICE_DIR/alpha-registration.yaml" \
    "the plugin that implements bridge_generate_registration gets a registration"
assert_false "the plugin that does not implement it gets no registration file" \
    test -f "$APPSERVICE_DIR/beta-registration.yaml"
assert_false "the incomplete plugin is not registered with the homeserver" \
    grep -q 'beta-registration' "$CONFIG_DIR/homeserver.yaml"

# --- Test: the summary counts bridges that were configured ---
write_hs_config
rm -f "$APPSERVICE_DIR"/*.yaml
declare -gA CONFIG=()
CONFIG["install_dir"]="$INSTALL_DIR"
CONFIG["homeserver.type"]="synapse"
CONFIG["domain.name"]="example.com"
CONFIG["bridges.enabled"]="alpha,beta,nosuchbridge"
BRIDGES_ENABLED=()
SETUP_OUT="$(SCRIPT_DIR="$TEST_TMP" bridges_setup 2>&1)" || true
assert_match "1 configured" "$SETUP_OUT" \
    "the summary counts the bridges that were configured, not the ones requested"

teardown_test_tmp
test_report
