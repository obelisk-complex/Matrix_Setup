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

# --- Test: bridge_generate_registration writes usable values, not just keys ---
# Asserting on the key name passes just as well when the value is empty, which
# is the failure that matters: an appservice with an empty as_token registers
# with the homeserver and then cannot authenticate to it.
HAVE_PYYAML=false
python3 -c 'import yaml' 2>/dev/null && HAVE_PYYAML=true

reg_field() {
    python3 "$TEST_TMP/yaml_field.py" "$1" "$2"
}

cat > "$TEST_TMP/yaml_field.py" <<'PYEOF'
import sys, yaml
cur = yaml.safe_load(open(sys.argv[1]))
for part in sys.argv[2].split('.'):
    if cur is None:
        break
    cur = cur[int(part)] if part.isdigit() else (cur.get(part) if isinstance(cur, dict) else None)
print('' if cur is None else cur)
PYEOF

for plugin in "$BRIDGE_DIR"/*.sh; do
    [[ -f "$plugin" ]] || continue
    basename=$(basename "$plugin" .sh)
    [[ "$basename" == _* ]] && continue

    reg_file="$TEST_TMP/${basename}-reg.yaml"
    rm -f "$reg_file"

    bash -c "
        source '$PROJECT_DIR/lib/00_constants.sh' 2>/dev/null
        source '$plugin' 2>/dev/null
        bridge_generate_registration '$reg_file' 'as-token-under-test' 'hs-token-under-test' 'example.com'
    " 2>/dev/null || true

    assert_file_exists "$reg_file" "$basename: registration file is created"
    [[ -f "$reg_file" ]] || continue

    if [[ "$HAVE_PYYAML" != "true" ]]; then
        skip_test "$basename: PyYAML not installed - registration value assertions skipped"
        continue
    fi

    assert_eq "as-token-under-test" "$(reg_field "$reg_file" as_token)" \
        "$basename: as_token carries the token it was given"
    assert_eq "hs-token-under-test" "$(reg_field "$reg_file" hs_token)" \
        "$basename: hs_token carries the token it was given"
    assert_ne "" "$(reg_field "$reg_file" id)" \
        "$basename: the appservice id is not empty"
    assert_ne "" "$(reg_field "$reg_file" sender_localpart)" \
        "$basename: sender_localpart is not empty"
    assert_match "example\.com" "$(reg_field "$reg_file" namespaces.users.0.regex)" \
        "$basename: the user namespace is scoped to the server name"
    assert_match "^https?://" "$(reg_field "$reg_file" url)" \
        "$basename: the appservice url is one the homeserver can reach"
done

# --- Test: bridge_compose_fragment names a real image and container ---
# `assert_match "image:"` matches even when the image value is empty, which is
# what an unset BRIDGE_*_IMAGE constant produces.
cat > "$TEST_TMP/frag_field.py" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
svc = next(iter(doc["services"].values()))
print(svc.get(sys.argv[2], ""))
PYEOF

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

    if [[ "$HAVE_PYYAML" != "true" ]]; then
        skip_test "$basename: PyYAML not installed - compose fragment value assertions skipped"
        continue
    fi

    frag_file="$TEST_TMP/${basename}-fragment.yml"
    { printf 'services:\n'; printf '%s\n' "$fragment"; } > "$frag_file"

    image=$(python3 "$TEST_TMP/frag_field.py" "$frag_file" image 2>/dev/null || echo "")
    assert_match "^[a-z0-9.]+(/[^:@[:space:]]+)+:[^[:space:]]+" "$image" \
        "$basename: the compose fragment names a resolvable image ($image)"
    assert_match "@sha256:[0-9a-f]{64}$" "$image" \
        "$basename: the bridge image is digest-pinned like every other image"
    assert_ne "" "$(python3 "$TEST_TMP/frag_field.py" "$frag_file" container_name 2>/dev/null || echo "")" \
        "$basename: the compose fragment names a container"
done

# --- Test: the metadata functions are called, not merely defined ---
for plugin in "$BRIDGE_DIR"/*.sh; do
    [[ -f "$plugin" ]] || continue
    basename=$(basename "$plugin" .sh)
    [[ "$basename" == _* ]] && continue

    meta=$(bash -c "
        source '$PROJECT_DIR/lib/00_constants.sh' 2>/dev/null
        source '$plugin' 2>/dev/null
        printf '%s|%s' \"\$(bridge_description)\" \"\$(bridge_requires_synapse)\"
    " 2>/dev/null) || meta="|"

    assert_ne "" "${meta%%|*}" "$basename: bridge_description returns a description"
    assert_match "^(true|false)$" "${meta##*|}" \
        "$basename: bridge_requires_synapse answers true or false"
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
