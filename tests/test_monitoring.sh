#!/usr/bin/env bash
# Tests for lib/18_monitoring.sh — the generated Prometheus scrape config.
#
# The two homeservers expose metrics differently: Synapse gets a dedicated
# `type: metrics` listener on 9000 (templates/configs/homeserver.synapse.yaml.tpl)
# and serves /_synapse/metrics there, while Dendrite has no metrics listener at
# all — `global.metrics.enabled: true` exposes /metrics on its ordinary HTTP
# port. Scraping the Synapse path and port on a Dendrite install collects
# nothing, silently.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/18_monitoring.sh"

setup_test_tmp

rollback_snapshot() { :; }

HAVE_PYYAML=false
if python3 -c 'import yaml' 2>/dev/null; then
    HAVE_PYYAML=true
fi

CONFIG_DIR="$TEST_TMP/config/monitoring"
mkdir -p "$CONFIG_DIR"

# Render prometheus.yml for one homeserver type and networking mode.
render_prometheus() {
    declare -gA CONFIG=()
    CONFIG["domain.name"]="example.com"
    CONFIG["homeserver.type"]="$1"
    COMPOSE_NETWORKING="$2"
    rm -f "$CONFIG_DIR/prometheus.yml"
    _monitoring_prometheus_config "$CONFIG_DIR" >/dev/null 2>&1
}

# Read one field of the homeserver scrape job. Uses a real YAML parser: a grep
# would match the same string in the prometheus or postgres job.
hs_job_field() {
    local field="$1" job="$2"
    python3 - "$CONFIG_DIR/prometheus.yml" "$field" "$job" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
field, job = sys.argv[2], sys.argv[3]
for j in doc["scrape_configs"]:
    if j["job_name"] == job:
        v = j.get(field)
        if isinstance(v, list):
            print(",".join(str(x) for x in v))
        else:
            print("" if v is None else v)
        break
else:
    print("<no such job>")
PY
}

if [[ "$HAVE_PYYAML" != "true" ]]; then
    skip_test "PyYAML not installed — prometheus.yml parse assertions skipped"
else
    # --- Test: Synapse keeps its dedicated metrics listener ---
    for mode in dns pod; do
        render_prometheus synapse "$mode"
        expected_host="homeserver"
        [[ "$mode" == "pod" ]] && expected_host="localhost"
        assert_eq "/_synapse/metrics" "$(hs_job_field metrics_path synapse)" \
            "synapse ($mode): scrape path is /_synapse/metrics"
        assert_eq "$expected_host:9000" \
            "$(python3 -c "
import sys, yaml
doc = yaml.safe_load(open('$CONFIG_DIR/prometheus.yml'))
for j in doc['scrape_configs']:
    if j['job_name'] == 'synapse':
        print(j['static_configs'][0]['targets'][0])
")" "synapse ($mode): scrapes the metrics listener on 9000"
    done

    # --- Test: Dendrite is scraped where it actually serves metrics ---
    for mode in dns pod; do
        render_prometheus dendrite "$mode"
        expected_host="homeserver"
        [[ "$mode" == "pod" ]] && expected_host="localhost"
        assert_eq "/metrics" "$(hs_job_field metrics_path dendrite)" \
            "dendrite ($mode): scrape path is /metrics, not the Synapse path"
        assert_eq "$expected_host:8008" \
            "$(python3 -c "
import sys, yaml
doc = yaml.safe_load(open('$CONFIG_DIR/prometheus.yml'))
for j in doc['scrape_configs']:
    if j['job_name'] == 'dendrite':
        print(j['static_configs'][0]['targets'][0])
")" "dendrite ($mode): scrapes the client API port, which has no metrics listener beside it"
    done

    # --- Test: the file stays valid YAML with one job per component ---
    render_prometheus synapse dns
    assert_eq "prometheus,synapse,postgres" \
        "$(python3 -c "
import yaml
doc = yaml.safe_load(open('$CONFIG_DIR/prometheus.yml'))
print(','.join(j['job_name'] for j in doc['scrape_configs']))
")" "the scrape config declares one job per component"
fi

teardown_test_tmp
test_report
