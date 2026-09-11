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
_TEST_NUM=$((_TEST_NUM + 1))
if toml_parse_file "$TEST_TMP/nonexistent.toml" 2>/dev/null; then
    echo "not ok $_TEST_NUM - should fail on missing file"
    _TEST_FAILURES=$((_TEST_FAILURES + 1))
else
    echo "ok $_TEST_NUM - fails on missing file"
fi

# --- Fallback selection when the Python backend is unusable ---
# Regression: _toml_parse_python fell through to its read loop whenever
# python3 failed, hit TOML_VALUES[""] with an empty key and killed the shell,
# so the documented pure-Bash fallback was unreachable.

cat > "$TEST_TMP/fallback.toml" << 'EOF'
name = "fallback-server"

[domain]
name = "example.com"
port = 8448
EOF

# Parsing runs in a child shell: a fatal Bash error (bad array subscript) aborts
# the whole shell, so an in-process call would take the test run down with it.
cat > "$TEST_TMP/parse_helper.sh" << 'HELPER'
#!/usr/bin/env bash
set -euo pipefail
QUIET="true"
source "$LIB_DIR/00_constants.sh" 2>/dev/null || true
source "$LIB_DIR/01_utils.sh" 2>/dev/null || true
source "$LIB_DIR/03_toml_parser.sh"
toml_parse_file "$1"
echo "COUNT=${#TOML_VALUES[@]}"
for k in "${!TOML_VALUES[@]}"; do
    printf 'KV %s=%s\n' "$k" "${TOML_VALUES[$k]}"
done | sort
HELPER

# Stub interpreter standing in for Python < 3.11: present on PATH, no tomllib.
mkdir -p "$TEST_TMP/stub_bin"
cat > "$TEST_TMP/stub_bin/python3" << 'STUB'
#!/usr/bin/env bash
echo "STUB_PYTHON3_INVOKED" >&2
: > "${TOML_TEST_STUB_MARKER:?}"
echo "ModuleNotFoundError: No module named 'tomllib'" >&2
exit 1
STUB
chmod +x "$TEST_TMP/stub_bin/python3"

# A stub that never runs is indistinguishable from a working parser, so prove
# it shadows the real interpreter and that it is audible before relying on it.
_stub_resolved=$(PATH="$TEST_TMP/stub_bin:$PATH" bash -c 'command -v python3')
assert_eq "$TEST_TMP/stub_bin/python3" "$_stub_resolved" \
    "stub python3 shadows the real interpreter on PATH"

_stub_probe_err=$(TOML_TEST_STUB_MARKER="$TEST_TMP/probe_marker" \
    PATH="$TEST_TMP/stub_bin:$PATH" bash -c 'python3 -c ""' 2>&1 || true)
assert_match "STUB_PYTHON3_INVOKED" "$_stub_probe_err" \
    "stub python3 announces itself on stderr when run"

# (a) python3 present, tomllib missing -> Bash fallback must parse the file.
_marker="$TEST_TMP/no_tomllib_marker"
rm -f "$_marker"
_rc=0
_out=$(LIB_DIR="$LIB_DIR" TOML_TEST_STUB_MARKER="$_marker" \
    PATH="$TEST_TMP/stub_bin:$PATH" \
    bash "$TEST_TMP/parse_helper.sh" "$TEST_TMP/fallback.toml" \
    2>"$TEST_TMP/no_tomllib_err") || _rc=$?

assert_file_exists "$_marker" "no-tomllib: stub python3 was actually executed"
assert_eq "0" "$_rc" "no-tomllib: toml_parse_file succeeds via Bash fallback"
assert_match "KV name=fallback-server" "$_out" "no-tomllib: top-level key parsed"
assert_match "KV domain.name=example.com" "$_out" "no-tomllib: table key parsed"
assert_match "KV domain.port=8448" "$_out" "no-tomllib: integer value parsed"
assert_eq "3" "$(grep -c '^KV ' <<< "$_out" || true)" \
    "no-tomllib: exactly the three declared keys are present"
assert_eq "" "$(grep '^KV =' <<< "$_out" || true)" \
    "no-tomllib: no empty-string key inserted"

# (b) python3 absent from PATH entirely.
_nopy_bin="$TEST_TMP/nopython_bin"
mkdir -p "$_nopy_bin"
IFS=':' read -ra _path_dirs <<< "$PATH"
for _d in "${_path_dirs[@]}"; do
    [[ -d "$_d" ]] || continue
    ln -s -t "$_nopy_bin" "$_d"/* 2>/dev/null || true
done
rm -f "$_nopy_bin"/python3*

assert_false "no-python3: python3 is genuinely absent from the stripped PATH" \
    env PATH="$_nopy_bin" bash -c 'command -v python3'
assert_true "no-python3: stripped PATH still resolves sed, so the case is honest" \
    env PATH="$_nopy_bin" bash -c 'command -v sed >/dev/null'

_rc=0
_out=$(LIB_DIR="$LIB_DIR" PATH="$_nopy_bin" \
    bash "$TEST_TMP/parse_helper.sh" "$TEST_TMP/fallback.toml" \
    2>"$TEST_TMP/nopython_err") || _rc=$?

assert_eq "0" "$_rc" "no-python3: toml_parse_file succeeds via Bash fallback"
assert_match "KV name=fallback-server" "$_out" "no-python3: top-level key parsed"
assert_match "KV domain.name=example.com" "$_out" "no-python3: table key parsed"
assert_eq "3" "$(grep -c '^KV ' <<< "$_out" || true)" \
    "no-python3: exactly the three declared keys are present"
assert_eq "" "$(grep '^KV =' <<< "$_out" || true)" \
    "no-python3: no empty-string key inserted"

# (c) Happy path: a real tomllib still handles the file, including syntax the
# Bash subset parser cannot read (multi-line arrays), which is how we know the
# Python backend was the one that ran.
cat > "$TEST_TMP/multiline.toml" << 'EOF'
name = "python-server"
items = [
  "alpha",
  "beta",
]
EOF

if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null; then
    _rc=0
    _out=$(LIB_DIR="$LIB_DIR" bash "$TEST_TMP/parse_helper.sh" \
        "$TEST_TMP/multiline.toml" 2>"$TEST_TMP/happy_err") || _rc=$?
    assert_eq "0" "$_rc" "tomllib: toml_parse_file succeeds"
    assert_match "KV name=python-server" "$_out" "tomllib: scalar key parsed"
    assert_match "KV items=alpha,beta" "$_out" \
        "tomllib: multi-line array joined, so the Python backend ran"
    assert_eq "" "$(cat "$TEST_TMP/happy_err")" "tomllib: happy path is silent"
else
    skip_test "tomllib: host python3 has no tomllib (needs 3.11+)"
    skip_test "tomllib: host python3 has no tomllib (needs 3.11+)"
    skip_test "tomllib: host python3 has no tomllib (needs 3.11+)"
    skip_test "tomllib: host python3 has no tomllib (needs 3.11+)"
fi

# (d) A successful parse that yields no keys must not produce a bad subscript.
# Real tomllib does exactly this for an empty TOML file; the stub makes the
# case reachable regardless of the host interpreter.
mkdir -p "$TEST_TMP/empty_bin"
cat > "$TEST_TMP/empty_bin/python3" << 'STUB'
#!/usr/bin/env bash
echo "STUB_EMPTY_PYTHON3_INVOKED" >&2
: > "${TOML_TEST_STUB_MARKER:?}"
exit 0
STUB
chmod +x "$TEST_TMP/empty_bin/python3"

_marker="$TEST_TMP/empty_marker"
rm -f "$_marker"
_rc=0
_out=$(LIB_DIR="$LIB_DIR" TOML_TEST_STUB_MARKER="$_marker" \
    PATH="$TEST_TMP/empty_bin:$PATH" \
    bash "$TEST_TMP/parse_helper.sh" "$TEST_TMP/fallback.toml" \
    2>"$TEST_TMP/empty_err") || _rc=$?

assert_file_exists "$_marker" "empty output: stub python3 was actually executed"
assert_eq "0" "$_rc" "empty output: parser survives a successful empty parse"
assert_match "COUNT=0" "$_out" "empty output: no keys recorded"
assert_eq "" "$(grep '^KV ' <<< "$_out" || true)" \
    "empty output: no empty-string key inserted"
assert_no_match "bad array subscript" "$(cat "$TEST_TMP/empty_err")" \
    "empty output: no bad array subscript error"

teardown_test_tmp
test_report
