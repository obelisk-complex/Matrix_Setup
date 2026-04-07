#!/usr/bin/env bash
# Tests for lib/03_toml_parser.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"
source "$LIB_DIR/03_toml_parser.sh"

setup_test_tmp

# --- Test: simple key-value pairs ---
cat > "$TEST_TMP/simple.toml" << 'EOF'
name = "test-server"
port = 8008
enabled = true
EOF

TOML_VALUES=()
toml_parse_file "$TEST_TMP/simple.toml"

assert_eq "test-server" "${TOML_VALUES[name]:-}" "parse simple string value"
assert_eq "8008" "${TOML_VALUES[port]:-}" "parse integer value"
assert_eq "true" "${TOML_VALUES[enabled]:-}" "parse boolean value"

# --- Test: table sections ---
cat > "$TEST_TMP/tables.toml" << 'EOF'
[domain]
name = "example.com"
confirmed = true

[homeserver]
type = "synapse"
EOF

TOML_VALUES=()
toml_parse_file "$TEST_TMP/tables.toml"

assert_eq "example.com" "${TOML_VALUES[domain.name]:-}" "parse table.key string"
assert_eq "true" "${TOML_VALUES[domain.confirmed]:-}" "parse table.key boolean"
assert_eq "synapse" "${TOML_VALUES[homeserver.type]:-}" "parse second table"

# --- Test: nested tables ---
cat > "$TEST_TMP/nested.toml" << 'EOF'
[bridges.telegram]
api_id = "12345"
api_hash = "abcdef"
EOF

TOML_VALUES=()
toml_parse_file "$TEST_TMP/nested.toml"

assert_eq "12345" "${TOML_VALUES[bridges.telegram.api_id]:-}" "parse nested table key"
assert_eq "abcdef" "${TOML_VALUES[bridges.telegram.api_hash]:-}" "parse nested table second key"

# --- Test: quoted strings with special chars ---
cat > "$TEST_TMP/quoted.toml" << 'EOF'
password = "p@ss=w0rd/with\"special"
empty = ""
EOF

TOML_VALUES=()
toml_parse_file "$TEST_TMP/quoted.toml"

assert_ne "" "${TOML_VALUES[password]:-}" "parse quoted string with special chars"
assert_eq "" "${TOML_VALUES[empty]:-}" "parse empty string"

# --- Test: comments and blank lines ---
cat > "$TEST_TMP/comments.toml" << 'EOF'
# This is a comment
key1 = "value1"

  # Indented comment
key2 = "value2"  # Inline comment
EOF

TOML_VALUES=()
toml_parse_file "$TEST_TMP/comments.toml"

assert_eq "value1" "${TOML_VALUES[key1]:-}" "parse value after comment"
assert_eq "value2" "${TOML_VALUES[key2]:-}" "parse value with inline comment"

# --- Test: missing file ---
declare -gA TOML_VALUES=()
if toml_parse_file "$TEST_TMP/nonexistent.toml" 2>/dev/null; then
    echo "not ok - should fail on missing file"
else
    _TEST_NUM=$((_TEST_NUM + 1))
    echo "ok $_TEST_NUM - fails on missing file"
fi

teardown_test_tmp
test_report
