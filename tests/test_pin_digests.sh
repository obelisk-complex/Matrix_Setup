#!/usr/bin/env bash
# Tests for scripts/pin-digests.sh --check (the CI drift gate).
# Runs entirely offline: a curl stub on PATH answers the registry HEAD probe,
# so no image is ever fetched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_utils.sh"

setup_test_tmp
trap teardown_test_tmp EXIT

PINNED="sha256:1111111111111111111111111111111111111111111111111111111111111111"

# pin-digests.sh derives its constants path from its own location, so each
# scenario gets a throwaway repo layout: <root>/scripts + <root>/lib.
_make_tree() {
    local root="$TEST_TMP/$1" constants="$2"
    mkdir -p "$root/scripts" "$root/lib"
    cp "$PROJECT_DIR/scripts/pin-digests.sh" "$root/scripts/"
    printf '%s\n' "$constants" > "$root/lib/00_constants.sh"
    printf '%s\n' "$root"
}

mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/curl" << 'EOF'
#!/usr/bin/env bash
# Offline registry stub: replies to any manifest HEAD with $STUB_DIGEST.
printf 'HTTP/1.1 200 OK\r\n'
printf 'docker-content-digest: %s\r\n' "$STUB_DIGEST"
printf '\r\n'
EOF
chmod +x "$TEST_TMP/bin/curl"

_check() {
    local root="$1" rc=0
    STUB_DIGEST="$PINNED" PATH="$TEST_TMP/bin:$PATH" \
        bash "$root/scripts/pin-digests.sh" --check > "$root/out.txt" 2>&1 || rc=$?
    printf '%s\n' "$rc"
}

# --- Test: a constants file matching zero images must not pass ---
# The strict 'readonly NAME_IMAGE="..."' regex matching nothing means --check
# verified nothing; reporting OK would be a vacuous pass.
root=$(_make_tree zero 'declare -r SYNAPSE_IMAGE="docker.io/matrixdotorg/synapse:v1.0.0"')
assert_eq "1" "$(_check "$root")" "--check fails when no image declarations are parsed"
assert_no_match "OK: all image digests match" "$(cat "$root/out.txt")" \
    "--check does not claim success when it parsed nothing"

# --- Test: a partially parseable constants file must not pass ---
# Two images declared, one in a form the regex skips: the skipped image would
# go unverified while the run still reported success.
root=$(_make_tree partial "readonly SYNAPSE_IMAGE=\"docker.io/matrixdotorg/synapse:v1.0.0@$PINNED\"
readonly cinny_IMAGE=\"ghcr.io/cinnyapp/cinny:v4.0.0@$PINNED\"")
assert_eq "1" "$(_check "$root")" "--check fails when only some image declarations parse"

# --- Test: matching digests pass ---
root=$(_make_tree match "readonly SYNAPSE_IMAGE=\"docker.io/matrixdotorg/synapse:v1.0.0@$PINNED\"")
assert_eq "0" "$(_check "$root")" "--check passes when the pinned digest matches upstream"
assert_file_contains "$root/out.txt" "OK: all image digests match" \
    "--check reports success on a matching digest"

# --- Test: drift is still detected ---
root=$(_make_tree drift 'readonly SYNAPSE_IMAGE="docker.io/matrixdotorg/synapse:v1.0.0@sha256:2222222222222222222222222222222222222222222222222222222222222222"')
assert_eq "1" "$(_check "$root")" "--check fails when the pinned digest differs from upstream"
assert_file_contains "$root/out.txt" "DRIFT: SYNAPSE_IMAGE" \
    "--check names the drifted image"

# --- Test: a drift failure says what to do about it ---
# Drift is a routine upstream event (a rebuilt tag) as often as a hostile one,
# so the gate stays a failure but has to be cheap to act on: the maintainer
# needs the re-pin command, not just a mismatch dump.
root=$(_make_tree drift_msg "readonly SYNAPSE_IMAGE=\"docker.io/matrixdotorg/synapse:v1.0.0@sha256:2222222222222222222222222222222222222222222222222222222222222222\"
readonly CADDY_IMAGE=\"docker.io/library/caddy:2.11.4@sha256:3333333333333333333333333333333333333333333333333333333333333333\"")
assert_eq "1" "$(_check "$root")" "--check fails when several images drift"
assert_file_contains "$root/out.txt" "2 image(s) drifted" \
    "--check reports how many images drifted"
assert_file_contains "$root/out.txt" "scripts/pin-digests.sh" \
    "--check names the command that re-pins them"

# --- Test: an unpinned image is drift ---
root=$(_make_tree unpinned 'readonly SYNAPSE_IMAGE="docker.io/matrixdotorg/synapse:v1.0.0"')
assert_eq "1" "$(_check "$root")" "--check fails when an image is not digest-pinned"

test_report
