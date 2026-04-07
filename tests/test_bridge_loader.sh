#!/usr/bin/env bash
# Tests for bridge plugin system (bridges/*.sh + lib/16_bridges.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"

setup_test_tmp

BRIDGE_DIR="$PROJECT_DIR/bridges"

# --- Test: all bridge plugins have required functions ---
required_functions=("bridge_name" "bridge_description" "bridge_image" "bridge_requires_synapse" "bridge_generate_registration" "bridge_compose_fragment")

for plugin in "$BRIDGE_DIR"/*.sh; do
    [[ -f "$plugin" ]] || continue
    basename=$(basename "$plugin" .sh)
    [[ "$basename" == _* ]] && continue

    for func in "${required_functions[@]}"; do
        _TEST_NUM=$((_TEST_NUM + 1))
        if bash -c "source '$plugin' 2>/dev/null; declare -f $func" &>/dev/null; then
            echo "ok $_TEST_NUM - $basename implements $func"
        else
            echo "not ok $_TEST_NUM - $basename missing $func"
            _TEST_FAILURES=$((_TEST_FAILURES + 1))
        fi
    done
done

# --- Test: bridge_name returns non-empty string ---
for plugin in "$BRIDGE_DIR"/*.sh; do
    [[ -f "$plugin" ]] || continue
    basename=$(basename "$plugin" .sh)
    [[ "$basename" == _* ]] && continue

    name=$(bash -c "
        source '$PROJECT_DIR/lib/00_constants.sh' 2>/dev/null
        source '$plugin' 2>/dev/null
        bridge_name
    " 2>/dev/null) || name=""

    assert_ne "" "$name" "$basename: bridge_name returns value"
done

# --- Test: bridge_image returns a valid image reference ---
for plugin in "$BRIDGE_DIR"/*.sh; do
    [[ -f "$plugin" ]] || continue
    basename=$(basename "$plugin" .sh)
    [[ "$basename" == _* ]] && continue

    image=$(bash -c "
        source '$PROJECT_DIR/lib/00_constants.sh' 2>/dev/null
        source '$plugin' 2>/dev/null
        bridge_image
    " 2>/dev/null) || image=""

    assert_match ':' "$image" "$basename: bridge_image contains tag"
    assert_match '/' "$image" "$basename: bridge_image contains registry path"
done

# --- Test: bridge_generate_registration creates valid YAML ---
for plugin in "$BRIDGE_DIR"/*.sh; do
    [[ -f "$plugin" ]] || continue
    basename=$(basename "$plugin" .sh)
    [[ "$basename" == _* ]] && continue

    reg_file="$TEST_TMP/${basename}-reg.yaml"

    bash -c "
        source '$PROJECT_DIR/lib/00_constants.sh' 2>/dev/null
        source '$plugin' 2>/dev/null
        bridge_generate_registration '$reg_file' 'test_as_token' 'test_hs_token' 'example.com'
    " 2>/dev/null || true

    if [[ -f "$reg_file" ]]; then
        assert_file_contains "$reg_file" "as_token" "$basename: registration has as_token"
        assert_file_contains "$reg_file" "hs_token" "$basename: registration has hs_token"
        assert_file_contains "$reg_file" "example.com" "$basename: registration has domain"
    else
        _TEST_NUM=$((_TEST_NUM + 1))
        echo "not ok $_TEST_NUM - $basename: registration file not created"
        _TEST_FAILURES=$((_TEST_FAILURES + 1))
    fi
done

# --- Test: bridge_compose_fragment outputs valid content ---
for plugin in "$BRIDGE_DIR"/*.sh; do
    [[ -f "$plugin" ]] || continue
    basename=$(basename "$plugin" .sh)
    [[ "$basename" == _* ]] && continue

    fragment=$(bash -c "
        source '$PROJECT_DIR/lib/00_constants.sh' 2>/dev/null
        declare -gA CONFIG=([install_dir]='/opt/matrix' [domain.name]='example.com')
        COMPOSE_NETWORKING='dns'
        VOLUME_LABEL=''
        source '$plugin' 2>/dev/null
        bridge_compose_fragment
    " 2>/dev/null) || fragment=""

    assert_match "image:" "$fragment" "$basename: compose fragment has image"
    assert_match "container_name:" "$fragment" "$basename: compose fragment has container_name"
done

# --- Test: no duplicate bridge IDs in registrations ---
declare -A seen_ids=()
for plugin in "$BRIDGE_DIR"/*.sh; do
    [[ -f "$plugin" ]] || continue
    basename=$(basename "$plugin" .sh)
    [[ "$basename" == _* ]] && continue

    reg_file="$TEST_TMP/${basename}-reg.yaml"
    if [[ -f "$reg_file" ]]; then
        bridge_id=$(grep '^id:' "$reg_file" | head -1 | awk '{print $2}')
        _TEST_NUM=$((_TEST_NUM + 1))
        if [[ -n "${seen_ids[$bridge_id]:-}" ]]; then
            echo "not ok $_TEST_NUM - duplicate bridge ID: $bridge_id"
            _TEST_FAILURES=$((_TEST_FAILURES + 1))
        else
            seen_ids["$bridge_id"]=1
            echo "ok $_TEST_NUM - unique bridge ID: $bridge_id"
        fi
    fi
done

teardown_test_tmp
test_report
