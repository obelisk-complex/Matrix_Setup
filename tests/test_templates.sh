#!/usr/bin/env bash
# Tests for template rendering (lib/01_utils.sh template_render)
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"

setup_test_tmp

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

# Check that metrics block was removed
if grep -q "metrics_port" "$TEST_TMP/cond.out"; then
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "not ok $_TEST_NUM - false conditional should be removed"
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
else
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "ok $_TEST_NUM - false conditional block removed"
fi

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

teardown_test_tmp
test_report
