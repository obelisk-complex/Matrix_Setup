#!/usr/bin/env bash
# Tests for compose fragment templates (structure and content validation)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"

setup_test_tmp

TEMPLATES_DIR="$PROJECT_DIR/templates/compose"

# --- Test: all compose templates exist ---
expected_templates=("base.yml" "postgres.yml" "synapse.yml" "dendrite.yml" "caddy.yml" "coturn.yml" "webclient.yml" "admin.yml" "monitoring.yml")

for tpl in "${expected_templates[@]}"; do
    assert_file_exists "$TEMPLATES_DIR/$tpl" "compose template: $tpl"
done

# --- Test: base.yml has networks and volumes ---
assert_file_contains "$TEMPLATES_DIR/base.yml" "networks:" "base.yml has networks"
assert_file_contains "$TEMPLATES_DIR/base.yml" "volumes:" "base.yml has volumes"
assert_file_contains "$TEMPLATES_DIR/base.yml" "matrix-net:" "base.yml defines matrix-net"

# --- Test: postgres.yml has healthcheck ---
assert_file_contains "$TEMPLATES_DIR/postgres.yml" "healthcheck:" "postgres has healthcheck"
assert_file_contains "$TEMPLATES_DIR/postgres.yml" "pg_isready" "postgres healthcheck uses pg_isready"

# --- Test: synapse.yml has required config ---
assert_file_contains "$TEMPLATES_DIR/synapse.yml" "homeserver.yaml" "synapse mounts homeserver.yaml"
assert_file_contains "$TEMPLATES_DIR/synapse.yml" "depends_on:" "synapse depends on postgres"
assert_file_contains "$TEMPLATES_DIR/synapse.yml" "healthcheck:" "synapse has healthcheck"

# --- Test: dendrite.yml has required config ---
assert_file_contains "$TEMPLATES_DIR/dendrite.yml" "dendrite.yaml" "dendrite mounts dendrite.yaml"
assert_file_contains "$TEMPLATES_DIR/dendrite.yml" "depends_on:" "dendrite depends on postgres"

# --- Test: caddy.yml has port mappings ---
assert_file_contains "$TEMPLATES_DIR/caddy.yml" "ports:" "caddy has ports"
assert_file_contains "$TEMPLATES_DIR/caddy.yml" "Caddyfile" "caddy mounts Caddyfile"
assert_file_contains "$TEMPLATES_DIR/caddy.yml" "depends_on:" "caddy depends on homeserver"

# --- Test: coturn.yml uses host networking ---
assert_file_contains "$TEMPLATES_DIR/coturn.yml" "network_mode: host" "coturn uses host network"
assert_file_contains "$TEMPLATES_DIR/coturn.yml" "turnserver.conf" "coturn mounts config"

# --- Test: monitoring.yml has prometheus and grafana ---
assert_file_contains "$TEMPLATES_DIR/monitoring.yml" "prometheus:" "monitoring has prometheus"
assert_file_contains "$TEMPLATES_DIR/monitoring.yml" "grafana:" "monitoring has grafana"
assert_file_contains "$TEMPLATES_DIR/monitoring.yml" "prometheus-data:" "monitoring has prometheus volume"
assert_file_contains "$TEMPLATES_DIR/monitoring.yml" "grafana-data:" "monitoring has grafana volume"

# --- Test: admin.yml connects to homeserver ---
assert_file_contains "$TEMPLATES_DIR/admin.yml" "REACT_APP_SERVER" "admin has server env var"
assert_file_contains "$TEMPLATES_DIR/admin.yml" "depends_on:" "admin depends on homeserver"

# --- Test: webclient.yml has healthcheck ---
assert_file_contains "$TEMPLATES_DIR/webclient.yml" "healthcheck:" "webclient has healthcheck"
assert_file_contains "$TEMPLATES_DIR/webclient.yml" "config.json" "webclient mounts config.json"

# --- Test: all compose templates have 'services:' key ---
for tpl in "${expected_templates[@]}"; do
    [[ "$tpl" == "base.yml" ]] && continue  # base only has networks/volumes
    assert_file_contains "$TEMPLATES_DIR/$tpl" "services:" "$tpl has services key"
done

# --- Test: template variables use {{VARIABLE}} syntax ---
for tpl in postgres.yml synapse.yml caddy.yml coturn.yml; do
    if grep -q '{{' "$TEMPLATES_DIR/$tpl"; then
        _TEST_NUM=$((_TEST_NUM + 1))
        echo "ok $_TEST_NUM - $tpl uses template variables"
    else
        _TEST_NUM=$((_TEST_NUM + 1))
        echo "not ok $_TEST_NUM - $tpl has no template variables"
    fi
done

teardown_test_tmp
test_report
