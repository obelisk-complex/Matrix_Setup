#!/usr/bin/env bash
# Matrix Stack Setup — Integration Test
# Run inside a Vagrant VM with Podman installed.
# Tests headless mode with a minimal TOML config against localhost.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
PASSED=0
FAILED=0

log() { printf '[TEST] %s\n' "$*"; }
pass() { log "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { log "FAIL: $1"; FAILED=$((FAILED + 1)); }

# --- Pre-flight ---
log "=== Integration Test ==="
log "OS: $(cat /etc/os-release | grep ^PRETTY_NAME | cut -d= -f2 | tr -d '"')"
log "Podman: $(podman --version 2>/dev/null || echo 'NOT FOUND')"

# 1. Unit tests pass
log "Running unit tests..."
if bash "$PROJECT_DIR/tests/test_runner.sh" &>/dev/null; then
    pass "unit tests"
else
    fail "unit tests"
fi

# 2. Bash syntax check
log "Checking bash syntax..."
syntax_ok=true
for f in "$PROJECT_DIR"/setup.sh "$PROJECT_DIR"/lib/*.sh "$PROJECT_DIR"/bridges/*.sh; do
    if ! bash -n "$f" 2>/dev/null; then
        fail "syntax: $(basename "$f")"
        syntax_ok=false
    fi
done
if $syntax_ok; then
    pass "all scripts pass bash -n"
fi

# 3. Generate example config
log "Testing --generate-config..."
if bash "$PROJECT_DIR/setup.sh" --generate-config &>/dev/null; then
    pass "--generate-config"
else
    fail "--generate-config"
fi

# 4. Help flag
log "Testing --help..."
if bash "$PROJECT_DIR/setup.sh" --help 2>&1 | grep -q "headless"; then
    pass "--help output"
else
    fail "--help output"
fi

# 5. Config validation in headless mode (should fail without proper config)
log "Testing config validation..."
cat > /tmp/test-invalid.toml << EOF
[domain]
name = ""
confirmed = true
EOF

if bash "$PROJECT_DIR/setup.sh" --headless --config /tmp/test-invalid.toml 2>&1 | grep -qi "error\|fail"; then
    pass "invalid config rejected"
else
    fail "invalid config should have been rejected"
fi

# 6. Template rendering
log "Testing template rendering..."
if bash -c "
    source '$PROJECT_DIR/lib/00_constants.sh'
    source '$PROJECT_DIR/lib/01_utils.sh'
    declare -A vars=([DOMAIN]='test.local' [FEDERATION]='true')
    template_render '$PROJECT_DIR/templates/configs/Caddyfile.tpl' '/tmp/test-caddy.out' vars
    grep -q 'test.local' /tmp/test-caddy.out
" 2>/dev/null; then
    pass "template rendering"
else
    fail "template rendering"
fi

# 7. Podman is functional
log "Testing Podman..."
if podman info &>/dev/null; then
    pass "podman info"
else
    fail "podman info"
fi

# 8. Test secret generation
log "Testing secret generation..."
if bash -c "
    source '$PROJECT_DIR/lib/00_constants.sh'
    source '$PROJECT_DIR/lib/01_utils.sh'
    source '$PROJECT_DIR/lib/25_rollback.sh'
    source '$PROJECT_DIR/lib/08_secrets.sh'
    s1=\$(_gen_secret)
    s2=\$(_gen_secret)
    [[ -n \"\$s1\" && -n \"\$s2\" && \"\$s1\" != \"\$s2\" ]]
" 2>/dev/null; then
    pass "secret generation"
else
    fail "secret generation"
fi

# Summary
echo ""
log "=== Results: $PASSED passed, $FAILED failed ==="
[[ $FAILED -eq 0 ]] && exit 0 || exit 1
